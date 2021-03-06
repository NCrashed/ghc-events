{-# LANGUAGE CPP,BangPatterns #-}
{-# OPTIONS_GHC -funbox-strict-fields -fwarn-incomplete-patterns #-}
{-
 -   Parser functions for GHC RTS EventLog framework.
 -}

module GHC.RTS.Events (
       -- * Parsers
       getHeader,
       getEvent,
       standardParsers,
       ghc6Parsers,
       ghc7Parsers,
       mercuryParsers,
       perfParsers,
       pre77StopParsers,
       ghc782StopParser,
       post782StopParser,
       parRTSParsers,
       -- * The event log types
       EventLog(..),
       Header(..),
       Data(..),
       EventType(..),
       Event(..),
       EventInfo(..),
       ThreadStopStatus(..),
       CapsetType(..),
       Timestamp,
       ThreadId,
       TaskId,
       KernelThreadId(..),
       -- some types for the parallel RTS
       ProcessId,
       MachineId,
       PortId,
       MessageSize,
       MessageTag(..),

       -- * Functions that assist reading and writing event logs
       putEvent,
       PutEvents,
       putEventLog,

       -- * Utilities
       CapEvent(..), sortEvents,
       buildEventTypeMap,

       -- * Printing
       showEventInfo, showThreadStopStatus,
       ppEventLog, ppEventType, ppEvent, ppEvent',

       -- * Perf events
       nEVENT_PERF_NAME, nEVENT_PERF_COUNTER, nEVENT_PERF_TRACEPOINT,
       sz_perf_num, sz_kernel_tid,

       -- * For compatibility with old clients
       -- readEventLogFromFile, TODO
       spec,
       time,
  ) where

{- Libraries. -}
import Data.Binary
import Data.Binary.Get ()
import qualified Data.Binary.Get as G
import Data.Binary.Put
import Control.Monad (when, replicateM)
import Data.IntMap (IntMap)
import qualified Data.IntMap as M
import Data.Function hiding (id)
import Data.List
import Data.Maybe (fromMaybe, fromJust)
import Text.Printf
import Data.Array
import Prelude hiding (gcd, rem, id)

import GHC.RTS.EventParserUtils
import GHC.RTS.EventTypes


#define EVENTLOG_CONSTANTS_ONLY
#include "EventLogFormat.h"

getEventType :: Get EventType
getEventType = do
           etNum <- get
           size <- get :: Get EventTypeSize
           let etSize = if size == 0xffff then Nothing else Just size
           -- 0xffff indicates variable-sized event
           etDescLen <- get :: Get EventTypeDescLen
           etDesc <- getEtDesc (fromIntegral etDescLen)
           etExtraLen <- get :: Get Word32
           G.skip (fromIntegral etExtraLen)
           ete <- get :: Get Marker
           when (ete /= EVENT_ET_END) $
              fail "Event Type end marker not found."
           return (EventType etNum etDesc etSize)
           where
             getEtDesc :: Int -> Get [Char]
             getEtDesc s = replicateM s (get :: Get Char)



getHeader :: Get Header
getHeader = do
            hdrb <- get :: Get Marker
            when (hdrb /= EVENT_HEADER_BEGIN) $
                 fail "Header begin marker not found"
            hetm <- get :: Get Marker
            when (hetm /= EVENT_HET_BEGIN) $
                 fail "Header Event Type begin marker not found"
            ets <- getEventTypes
            emark <- get :: Get Marker
            when (emark /= EVENT_HEADER_END) $
                 fail "Header end marker not found"
            db <- get :: Get Marker
            when (db /= EVENT_DATA_BEGIN) $
                  fail "My Data begin marker not found"
            return $ Header ets
     where
      getEventTypes :: Get [EventType]
      getEventTypes = do
          m <- get :: Get Marker
          case m of
             EVENT_ET_BEGIN -> do
                  et <- getEventType
                  nextET <- getEventTypes
                  return (et : nextET)
             EVENT_HET_END ->
                  return []
             _ ->
                  fail "Malformed list of Event Types in header"

getEvent :: EventParsers -> Get (Maybe Event)
getEvent (EventParsers parsers) = do
  etRef <- get :: Get EventTypeNum
  if etRef == EVENT_DATA_END
     then return Nothing
     else do !ts   <- get
             spc <- parsers ! fromIntegral etRef
             return $ Just (Event ts spc undefined)

--
-- standardEventParsers.
--
standardParsers :: [EventParser EventInfo]
standardParsers = [
 (FixedSizeParser EVENT_STARTUP sz_cap (do -- (n_caps)
      c <- get :: Get CapNo
      return Startup{ n_caps = fromIntegral c }
   )),

 (FixedSizeParser EVENT_BLOCK_MARKER (sz_block_size + sz_time + sz_cap) (do -- (size, end_time, cap)
      block_size <- get :: Get BlockSize
      end_time <- get :: Get Timestamp
      c <- get :: Get CapNo
      return EventBlock { end_time   = end_time,
                          cap        = fromIntegral c,
                          block_size = ((fromIntegral block_size) -
                                        (fromIntegral sz_block_event))
                        }
   )),

 -- EVENT_SHUTDOWN is replaced by EVENT_CAP_DELETE and GHC 7.6+
 -- no longer generate the event; should be removed at some point
 (simpleEvent EVENT_SHUTDOWN Shutdown),

 (simpleEvent EVENT_REQUEST_SEQ_GC RequestSeqGC),

 (simpleEvent EVENT_REQUEST_PAR_GC RequestParGC),

 (simpleEvent EVENT_GC_START StartGC),

 (simpleEvent EVENT_GC_WORK GCWork),

 (simpleEvent EVENT_GC_IDLE GCIdle),

 (simpleEvent EVENT_GC_DONE GCDone),

 (simpleEvent EVENT_GC_END EndGC),

 (simpleEvent EVENT_GC_GLOBAL_SYNC GlobalSyncGC),

 (FixedSizeParser EVENT_GC_STATS_GHC (sz_capset + 2 + 5*8 + 4) (do  -- (heap_capset, generation, copied_bytes, slop_bytes, frag_bytes, par_n_threads, par_max_copied, par_tot_copied)
      heapCapset   <- get
      gen          <- get :: Get Word16
      copied       <- get :: Get Word64
      slop         <- get :: Get Word64
      frag         <- get :: Get Word64
      parNThreads  <- get :: Get Word32
      parMaxCopied <- get :: Get Word64
      parTotCopied <- get :: Get Word64
      return GCStatsGHC{ gen = fromIntegral gen
                       , parNThreads = fromIntegral parNThreads
                       , ..}
 )),

 (FixedSizeParser EVENT_HEAP_ALLOCATED (sz_capset + 8) (do  -- (heap_capset, alloc_bytes)
      heapCapset <- get
      allocBytes <- get
      return HeapAllocated{..}
 )),

 (FixedSizeParser EVENT_HEAP_SIZE (sz_capset + 8) (do  -- (heap_capset, size_bytes)
      heapCapset <- get
      sizeBytes  <- get
      return HeapSize{..}
 )),

 (FixedSizeParser EVENT_HEAP_LIVE (sz_capset + 8) (do  -- (heap_capset, live_bytes)
      heapCapset <- get
      liveBytes  <- get
      return HeapLive{..}
 )),

 (FixedSizeParser EVENT_HEAP_INFO_GHC (sz_capset + 2 + 4*8) (do  -- (heap_capset, n_generations, max_heap_size, alloc_area_size, mblock_size, block_size)
      heapCapset    <- get
      gens          <- get :: Get Word16
      maxHeapSize   <- get :: Get Word64
      allocAreaSize <- get :: Get Word64
      mblockSize    <- get :: Get Word64
      blockSize     <- get :: Get Word64
      return HeapInfoGHC{gens = fromIntegral gens, ..}
 )),

 (FixedSizeParser EVENT_CAP_CREATE (sz_cap) (do  -- (cap)
      cap <- get :: Get CapNo
      return CapCreate{cap = fromIntegral cap}
 )),

 (FixedSizeParser EVENT_CAP_DELETE (sz_cap) (do  -- (cap)
      cap <- get :: Get CapNo
      return CapDelete{cap = fromIntegral cap}
 )),

 (FixedSizeParser EVENT_CAP_DISABLE (sz_cap) (do  -- (cap)
      cap <- get :: Get CapNo
      return CapDisable{cap = fromIntegral cap}
 )),

 (FixedSizeParser EVENT_CAP_ENABLE (sz_cap) (do  -- (cap)
      cap <- get :: Get CapNo
      return CapEnable{cap = fromIntegral cap}
 )),

 (FixedSizeParser EVENT_CAPSET_CREATE (sz_capset + sz_capset_type) (do -- (capset, capset_type)
      cs <- get
      ct <- fmap mkCapsetType get
      return CapsetCreate{capset=cs,capsetType=ct}
   )),

 (FixedSizeParser EVENT_CAPSET_DELETE sz_capset (do -- (capset)
      cs <- get
      return CapsetDelete{capset=cs}
   )),

 (FixedSizeParser EVENT_CAPSET_ASSIGN_CAP (sz_capset + sz_cap) (do -- (capset, cap)
      cs <- get
      cp <- get :: Get CapNo
      return CapsetAssignCap{capset=cs,cap=fromIntegral cp}
   )),

 (FixedSizeParser EVENT_CAPSET_REMOVE_CAP (sz_capset + sz_cap) (do -- (capset, cap)
      cs <- get
      cp <- get :: Get CapNo
      return CapsetRemoveCap{capset=cs,cap=fromIntegral cp}
   )),

 (FixedSizeParser EVENT_OSPROCESS_PID (sz_capset + sz_pid) (do -- (capset, pid)
      cs <- get
      pd <- get
      return OsProcessPid{capset=cs,pid=pd}
   )),

 (FixedSizeParser EVENT_OSPROCESS_PPID (sz_capset + sz_pid) (do -- (capset, ppid)
      cs <- get
      pd <- get
      return OsProcessParentPid{capset=cs,ppid=pd}
  )),

 (FixedSizeParser EVENT_WALL_CLOCK_TIME (sz_capset + 8 + 4) (do -- (capset, unix_epoch_seconds, nanoseconds)
      cs <- get
      s  <- get
      ns <- get
      return WallClockTime{capset=cs,sec=s,nsec=ns}
  )),

 (VariableSizeParser EVENT_LOG_MSG (do -- (msg)
      num <- get :: Get Word16
      string <- getString num
      return Message{ msg = string }
   )),
 (VariableSizeParser EVENT_USER_MSG (do -- (msg)
      num <- get :: Get Word16
      string <- getString num
      return UserMessage{ msg = string }
   )),
    (VariableSizeParser EVENT_USER_MARKER (do -- (markername)
      num <- get :: Get Word16
      string <- getString num
      return UserMarker{ markername = string }
   )),
 (VariableSizeParser EVENT_PROGRAM_ARGS (do -- (capset, [arg])
      num <- get :: Get Word16
      cs <- get
      string <- getString (num - sz_capset)
      return ProgramArgs{ capset = cs
                        , args = splitNull string }
   )),
 (VariableSizeParser EVENT_PROGRAM_ENV (do -- (capset, [arg])
      num <- get :: Get Word16
      cs <- get
      string <- getString (num - sz_capset)
      return ProgramEnv{ capset = cs
                       , env = splitNull string }
   )),
 (VariableSizeParser EVENT_RTS_IDENTIFIER (do -- (capset, str)
      num <- get :: Get Word16
      cs <- get
      string <- getString (num - sz_capset)
      return RtsIdentifier{ capset = cs
                          , rtsident = string }
   )),

 (VariableSizeParser EVENT_INTERN_STRING (do -- (str, id)
      num <- get :: Get Word16
      string <- getString (num - sz_string_id)
      sId <- get :: Get StringId
      return (InternString string sId)
    )),

 (VariableSizeParser EVENT_THREAD_LABEL (do -- (thread, str)
      num <- get :: Get Word16
      tid <- get
      str <- getString (num - sz_tid)
      return ThreadLabel{ thread      = tid
                        , threadlabel = str }
    ))
 ]

-- Parsers valid for GHC7 but not GHC6.
ghc7Parsers :: [EventParser EventInfo]
ghc7Parsers = [
 (FixedSizeParser EVENT_CREATE_THREAD sz_tid (do  -- (thread)
      t <- get
      return CreateThread{thread=t}
   )),

 (FixedSizeParser EVENT_RUN_THREAD sz_tid (do  --  (thread)
      t <- get
      return RunThread{thread=t}
   )),

 (FixedSizeParser EVENT_THREAD_RUNNABLE sz_tid (do  -- (thread)
      t <- get
      return ThreadRunnable{thread=t}
   )),

 (FixedSizeParser EVENT_MIGRATE_THREAD (sz_tid + sz_cap) (do  --  (thread, newCap)
      t  <- get
      nc <- get :: Get CapNo
      return MigrateThread{thread=t,newCap=fromIntegral nc}
   )),

 -- Yes, EVENT_RUN/STEAL_SPARK are deprecated, but see the explanation in the
 -- 'ghc6Parsers' section below. Since we're parsing them anyway, we might
 -- as well convert them to the new SparkRun/SparkSteal events.
 (FixedSizeParser EVENT_RUN_SPARK sz_tid (do  -- (thread)
      _ <- get :: Get ThreadId
      return SparkRun
   )),

 (FixedSizeParser EVENT_STEAL_SPARK (sz_tid + sz_cap) (do  -- (thread, victimCap)
      _  <- get :: Get ThreadId
      vc <- get :: Get CapNo
      return SparkSteal{victimCap=fromIntegral vc}
   )),

 (FixedSizeParser EVENT_CREATE_SPARK_THREAD sz_tid (do  -- (sparkThread)
      st <- get :: Get ThreadId
      return CreateSparkThread{sparkThread=st}
   )),

 (FixedSizeParser EVENT_SPARK_COUNTERS (7*8) (do -- (crt,dud,ovf,cnv,gcd,fiz,rem)
      crt <- get :: Get Word64
      dud <- get :: Get Word64
      ovf <- get :: Get Word64
      cnv <- get :: Get Word64
      gcd <- get :: Get Word64
      fiz <- get :: Get Word64
      rem <- get :: Get Word64
      return SparkCounters{sparksCreated    = crt, sparksDud       = dud,
                           sparksOverflowed = ovf, sparksConverted = cnv,
                           -- Warning: order of fiz and gcd reversed!
                           sparksFizzled    = fiz, sparksGCd       = gcd,
                           sparksRemaining  = rem}
   )),

 (simpleEvent EVENT_SPARK_CREATE   SparkCreate),
 (simpleEvent EVENT_SPARK_DUD      SparkDud),
 (simpleEvent EVENT_SPARK_OVERFLOW SparkOverflow),
 (simpleEvent EVENT_SPARK_RUN      SparkRun),
 (FixedSizeParser EVENT_SPARK_STEAL sz_cap (do  -- (victimCap)
      vc <- get :: Get CapNo
      return SparkSteal{victimCap=fromIntegral vc}
   )),
 (simpleEvent EVENT_SPARK_FIZZLE   SparkFizzle),
 (simpleEvent EVENT_SPARK_GC       SparkGC),

 (FixedSizeParser EVENT_TASK_CREATE (sz_taskid + sz_cap + sz_kernel_tid) (do  -- (taskID, cap, tid)
      taskId <- get :: Get TaskId
      cap    <- get :: Get CapNo
      tid    <- get :: Get KernelThreadId
      return TaskCreate{ taskId, cap = fromIntegral cap, tid }
   )),
 (FixedSizeParser EVENT_TASK_MIGRATE (sz_taskid + sz_cap*2) (do  -- (taskID, cap, new_cap)
      taskId  <- get :: Get TaskId
      cap     <- get :: Get CapNo
      new_cap <- get :: Get CapNo
      return TaskMigrate{ taskId, cap = fromIntegral cap
                                , new_cap = fromIntegral new_cap
                        }
   )),
 (FixedSizeParser EVENT_TASK_DELETE (sz_taskid) (do  -- (taskID)
      taskId <- get :: Get TaskId
      return TaskDelete{ taskId }
   )),

 (FixedSizeParser EVENT_THREAD_WAKEUP (sz_tid + sz_cap) (do  -- (thread, other_cap)
      t <- get
      oc <- get :: Get CapNo
      return WakeupThread{thread=t,otherCap=fromIntegral oc}
   ))
 ]

-- special thread stop event parsers for GHC version 7.8.2
-- see [Stop status in GHC-7.8.2] in EventTypes.hs
ghc782StopParser :: EventParser EventInfo
ghc782StopParser =
 (FixedSizeParser EVENT_STOP_THREAD (sz_tid + sz_th_stop_status + sz_tid) (do
      -- (thread, status, info)
      t <- get
      s <- get :: Get RawThreadStopStatus
      i <- get :: Get ThreadId
      return StopThread{thread = t,
                        status = case () of
                                  _ | s > maxThreadStopStatus782
                                    -> NoStatus
                                    | s == 9 {- XXX yeuch -}
                                      -- GHC-7.8.2: 9 == BlockedOnBlackHole
                                    -> BlockedOnBlackHoleOwnedBy i
                                    | otherwise
                                    -> mkStopStatus782 s}
   ))

-- parsers for GHC < 7.8.2. Older versions do not use block info
-- (different length).  See [Stop status in GHC-7.8.2] in
-- EventTypes.hs
pre77StopParsers :: [EventParser EventInfo]
pre77StopParsers = [
 (FixedSizeParser EVENT_STOP_THREAD (sz_tid + sz_th_stop_status) (do
      -- (thread, status)
      t <- get
      s <- get :: Get RawThreadStopStatus
      return StopThread{thread=t, status = if s > maxThreadStopStatusPre77
                                              then NoStatus
                                              else mkStopStatus s}
                        -- older version of the event, no block info
   )),

 (FixedSizeParser EVENT_STOP_THREAD (sz_tid + sz_th_stop_status + sz_tid) 
    (do
      -- (thread, status, info)
      t <- get
      s <- get :: Get RawThreadStopStatus
      i <- get :: Get ThreadId
      return StopThread{thread = t,
                        status = case () of
                                  _ | s > maxThreadStopStatusPre77
                                    -> NoStatus
                                    | s == 8 {- XXX yeuch -}
                                      -- pre-7.7: 8==BlockedOnBlackhole
                                    -> BlockedOnBlackHoleOwnedBy i
                                    | otherwise
                                    -> mkStopStatus s}
    ))
  ]

-- parsers for GHC >= 7.8.3, always using block info field parser.
-- See [Stop status in GHC-7.8.2] in EventTypes.hs
post782StopParser :: EventParser EventInfo
post782StopParser = 
 (FixedSizeParser EVENT_STOP_THREAD (sz_tid + sz_th_stop_status + sz_tid) 
    (do
      -- (thread, status, info)
      t <- get
      s <- get :: Get RawThreadStopStatus
      i <- get :: Get ThreadId
      return StopThread{thread = t,
                        status = case () of
                                  _ | s > maxThreadStopStatus
                                    -> NoStatus
                                    | s == 8 {- XXX yeuch -}
                                      -- post-7.8.2: 8==BlockedOnBlackhole
                                    -> BlockedOnBlackHoleOwnedBy i
                                    | otherwise
                                    -> mkStopStatus s}
    ))

 -----------------------
 -- GHC 6.12 compat: GHC 6.12 reported the wrong sizes for some events,
 -- so we have to recognise those wrong sizes here for backwards
 -- compatibility.
ghc6Parsers :: [EventParser EventInfo]
ghc6Parsers = [
 (FixedSizeParser EVENT_STARTUP 0 (do
      -- BUG in GHC 6.12: the startup event was incorrectly
      -- declared as size 0, so we accept it here.
      c <- get :: Get CapNo
      return Startup{ n_caps = fromIntegral c }
   )),

 (FixedSizeParser EVENT_CREATE_THREAD sz_old_tid (do  -- (thread)
      t <- get
      return CreateThread{thread=t}
   )),

 (FixedSizeParser EVENT_RUN_THREAD sz_old_tid (do  --  (thread)
      t <- get
      return RunThread{thread=t}
   )),

 (FixedSizeParser EVENT_STOP_THREAD (sz_old_tid + 2) (do  -- (thread, status)
      t <- get
      s <- get :: Get RawThreadStopStatus
      return StopThread{thread=t, status = if s > maxThreadStopStatusPre77
                                              then NoStatus
                                              else mkStopStatus s}
                        -- older version of the event uses pre-77 encoding
                        -- (actually, it only uses encodings 0 to 5)
                        -- see [Stop status in GHC-7.8.2] in EventTypes.hs
   )),

 (FixedSizeParser EVENT_THREAD_RUNNABLE sz_old_tid (do  -- (thread)
      t <- get
      return ThreadRunnable{thread=t}
   )),

 (FixedSizeParser EVENT_MIGRATE_THREAD (sz_old_tid + sz_cap) (do  --  (thread, newCap)
      t  <- get
      nc <- get :: Get CapNo
      return MigrateThread{thread=t,newCap=fromIntegral nc}
   )),

 -- Note: it is vital that these two (EVENT_RUN/STEAL_SPARK) remain here (at
 -- least in the ghc6Parsers section) even though both events are deprecated.
 -- The reason is that .eventlog files created by the buggy GHC-6.12
 -- mis-declare the size of these two events. So we have to handle them
 -- specially here otherwise we'll get the wrong size, leading to us getting
 -- out of sync and eventual parse failure. Since we're parsing them anyway,
 -- we might as well convert them to the new SparkRun/SparkSteal events.
 (FixedSizeParser EVENT_RUN_SPARK sz_old_tid (do  -- (thread)
      _ <- get :: Get ThreadId
      return SparkRun
   )),

 (FixedSizeParser EVENT_STEAL_SPARK (sz_old_tid + sz_cap) (do  -- (thread, victimCap)
      _  <- get :: Get ThreadId
      vc <- get :: Get CapNo
      return SparkSteal{victimCap=fromIntegral vc}
   )),

 (FixedSizeParser EVENT_CREATE_SPARK_THREAD sz_old_tid (do  -- (sparkThread)
      st <- get :: Get ThreadId
      return CreateSparkThread{sparkThread=st}
   )),

 (FixedSizeParser EVENT_THREAD_WAKEUP (sz_old_tid + sz_cap) (do  -- (thread, other_cap)
      t <- get
      oc <- get :: Get CapNo
      return WakeupThread{thread=t,otherCap=fromIntegral oc}
   ))
 ]

-- Parsers for parallel events. Parameter is the thread_id size, to create
-- ghc6-parsers (using the wrong size) where necessary.
parRTSParsers :: EventTypeSize -> [EventParser EventInfo]
parRTSParsers sz_tid' = [
 (VariableSizeParser EVENT_VERSION (do -- (version)
      num <- get :: Get Word16
      string <- getString num
      return Version{ version = string }
   )),

 (VariableSizeParser EVENT_PROGRAM_INVOCATION (do -- (cmd. line)
      num <- get :: Get Word16
      string <- getString num
      return ProgramInvocation{ commandline = string }
   )),

 (simpleEvent EVENT_EDEN_START_RECEIVE EdenStartReceive),
 (simpleEvent EVENT_EDEN_END_RECEIVE   EdenEndReceive),

 (FixedSizeParser EVENT_CREATE_PROCESS sz_procid
    (do p <- get
        return CreateProcess{ process = p })
 ),

 (FixedSizeParser EVENT_KILL_PROCESS sz_procid
    (do p <- get
        return KillProcess{ process = p })
 ),

 (FixedSizeParser EVENT_ASSIGN_THREAD_TO_PROCESS (sz_tid' + sz_procid)
    (do t <- get
        p <- get
        return AssignThreadToProcess { thread = t, process = p })
 ),

 (FixedSizeParser EVENT_CREATE_MACHINE (sz_mid + sz_realtime)
    (do m <- get
        t <- get
        return CreateMachine { machine = m, realtime = t })
 ),

 (FixedSizeParser EVENT_KILL_MACHINE sz_mid
    (do m <- get :: Get MachineId
        return KillMachine { machine = m })
 ),

 (FixedSizeParser EVENT_SEND_MESSAGE
    (sz_msgtag + 2*sz_procid + 2*sz_tid' + sz_mid)
    (do tag <- get :: Get RawMsgTag
        sP  <- get :: Get ProcessId
        sT  <- get :: Get ThreadId
        rM  <- get :: Get MachineId
        rP  <- get :: Get ProcessId
        rIP <- get :: Get PortId
        return SendMessage { mesTag = toMsgTag tag,
                             senderProcess = sP,
                             senderThread = sT,
                             receiverMachine = rM,
                             receiverProcess = rP,
                             receiverInport = rIP
                           })
 ),

 (FixedSizeParser EVENT_RECEIVE_MESSAGE
    (sz_msgtag + 2*sz_procid + 2*sz_tid' + sz_mid + sz_mes)
    (do tag <- get :: Get Word8
        rP  <- get :: Get ProcessId
        rIP <- get :: Get PortId
        sM  <- get :: Get MachineId
        sP  <- get :: Get ProcessId
        sT  <- get :: Get ThreadId
        mS  <- get :: Get MessageSize
        return  ReceiveMessage { mesTag = toMsgTag tag,
                                 receiverProcess = rP,
                                 receiverInport = rIP,
                                 senderMachine = sM,
                                 senderProcess = sP,
                                 senderThread= sT,
                                 messageSize = mS
                               })
 ),

 (FixedSizeParser EVENT_SEND_RECEIVE_LOCAL_MESSAGE
    (sz_msgtag + 2*sz_procid + 2*sz_tid')
    (do tag <- get :: Get Word8
        sP  <- get :: Get ProcessId
        sT  <- get :: Get ThreadId
        rP  <- get :: Get ProcessId
        rIP <- get :: Get PortId
        return SendReceiveLocalMessage { mesTag = toMsgTag tag,
                                         senderProcess = sP,
                                         senderThread = sT,
                                         receiverProcess = rP,
                                         receiverInport = rIP
                                       })
 )]

mercuryParsers :: [EventParser EventInfo]
mercuryParsers = [
 (FixedSizeParser EVENT_MER_START_PAR_CONJUNCTION
    (sz_par_conj_dyn_id + sz_par_conj_static_id)
    (do dyn_id <- get
        static_id <- get
        return (MerStartParConjunction dyn_id static_id))
 ),

 (FixedSizeParser EVENT_MER_STOP_PAR_CONJUNCTION sz_par_conj_dyn_id
    (do dyn_id <- get
        return (MerEndParConjunction dyn_id))
 ),

 (FixedSizeParser EVENT_MER_STOP_PAR_CONJUNCT sz_par_conj_dyn_id
    (do dyn_id <- get
        return (MerEndParConjunct dyn_id))
 ),

 (FixedSizeParser EVENT_MER_CREATE_SPARK (sz_par_conj_dyn_id + sz_spark_id)
    (do dyn_id <- get
        spark_id <- get
        return (MerCreateSpark dyn_id spark_id))
 ),

 (FixedSizeParser EVENT_MER_FUT_CREATE (sz_future_id + sz_string_id)
    (do future_id <- get
        name_id <- get
        return (MerFutureCreate future_id name_id))
 ),

 (FixedSizeParser EVENT_MER_FUT_WAIT_NOSUSPEND (sz_future_id)
    (do future_id <- get
        return (MerFutureWaitNosuspend future_id))
 ),

 (FixedSizeParser EVENT_MER_FUT_WAIT_SUSPENDED (sz_future_id)
    (do future_id <- get
        return (MerFutureWaitSuspended future_id))
 ),

 (FixedSizeParser EVENT_MER_FUT_SIGNAL (sz_future_id)
    (do future_id <- get
        return (MerFutureSignal future_id))
 ),

 (simpleEvent EVENT_MER_LOOKING_FOR_GLOBAL_CONTEXT MerLookingForGlobalThread),
 (simpleEvent EVENT_MER_WORK_STEALING MerWorkStealing),
 (simpleEvent EVENT_MER_LOOKING_FOR_LOCAL_SPARK MerLookingForLocalSpark),

 (FixedSizeParser EVENT_MER_RELEASE_CONTEXT sz_tid
    (do thread_id <- get
        return (MerReleaseThread thread_id))
 ),

 (simpleEvent EVENT_MER_ENGINE_SLEEPING MerCapSleeping),
 (simpleEvent EVENT_MER_CALLING_MAIN MerCallingMain)

 ]

perfParsers :: [EventParser EventInfo]
perfParsers = [
 (VariableSizeParser EVENT_PERF_NAME (do -- (perf_num, name)
      num     <- get :: Get Word16
      perfNum <- get
      name    <- getString (num - sz_perf_num)
      return PerfName{perfNum, name}
   )),

 (FixedSizeParser EVENT_PERF_COUNTER (sz_perf_num + sz_kernel_tid + 8) (do -- (perf_num, tid, period)
      perfNum <- get
      tid     <- get
      period  <- get
      return PerfCounter{perfNum, tid, period}
  )),

 (FixedSizeParser EVENT_PERF_TRACEPOINT (sz_perf_num + sz_kernel_tid) (do -- (perf_num, tid)
      perfNum <- get
      tid     <- get
      return PerfTracepoint{perfNum, tid}
  ))
 ]

-- -----------------------------------------------------------------------------
-- Utilities

sortEvents :: [Event] -> [Event]
sortEvents = sortBy (compare `on` evTime)

buildEventTypeMap :: [EventType] -> IntMap EventType
buildEventTypeMap etypes = M.fromList [ (fromIntegral (num t),t) | t <- etypes ]

-----------------------------------------------------------------------------
-- Some pretty-printing support

showEventInfo :: EventInfo -> String
showEventInfo spc =
    case spc of
        EventBlock end_time cap _block_events ->
          printf "event block: cap %d, end time: %d\n" cap end_time
        Startup n_caps ->
          printf "startup: %d capabilities" n_caps
        CreateThread thread ->
          printf "creating thread %d" thread
        RunThread thread ->
          printf "running thread %d" thread
        StopThread thread status ->
          printf "stopping thread %d (%s)" thread (showThreadStopStatus status)
        ThreadRunnable thread ->
          printf "thread %d is runnable" thread
        MigrateThread thread newCap  ->
          printf "migrating thread %d to cap %d" thread newCap
        CreateSparkThread sparkThread ->
          printf "creating spark thread %d" sparkThread
        SparkCounters crt dud ovf cnv fiz gcd rem ->
          printf "spark stats: %d created, %d converted, %d remaining (%d overflowed, %d dud, %d GC'd, %d fizzled)" crt cnv rem ovf dud gcd fiz
        SparkCreate ->
          printf "spark created"
        SparkDud ->
          printf "dud spark discarded"
        SparkOverflow ->
          printf "overflowed spark discarded"
        SparkRun ->
          printf "running a local spark"
        SparkSteal victimCap ->
          printf "stealing a spark from cap %d" victimCap
        SparkFizzle ->
          printf "spark fizzled"
        SparkGC ->
          printf "spark GCed"
        TaskCreate taskId cap tid ->
          printf "task 0x%x created on cap %d with OS kernel thread %d"
                 taskId cap (kernelThreadId tid)
        TaskMigrate taskId cap new_cap ->
          printf "task 0x%x migrated from cap %d to cap %d"
                 taskId cap new_cap
        TaskDelete taskId ->
          printf "task 0x%x deleted" taskId
        Shutdown ->
          printf "shutting down"
        WakeupThread thread otherCap ->
          printf "waking up thread %d on cap %d" thread otherCap
        ThreadLabel thread label ->
          printf "thread %d has label \"%s\"" thread label
        RequestSeqGC ->
          printf "requesting sequential GC"
        RequestParGC ->
          printf "requesting parallel GC"
        StartGC ->
          printf "starting GC"
        EndGC ->
          printf "finished GC"
        GCWork ->
          printf "GC working"
        GCIdle ->
          printf "GC idle"
        GCDone ->
          printf "GC done"
        GlobalSyncGC ->
          printf "all caps stopped for GC"
        GCStatsGHC{..} ->
          printf "GC stats for heap capset %d: generation %d, %d bytes copied, %d bytes slop, %d bytes fragmentation, %d par threads, %d bytes max par copied, %d bytes total par copied" heapCapset gen copied slop frag parNThreads parMaxCopied parTotCopied
        HeapAllocated{..} ->
          printf "allocated on heap capset %d: %d total bytes till now" heapCapset allocBytes
        HeapSize{..} ->
          printf "size of heap capset %d: %d bytes" heapCapset sizeBytes
        HeapLive{..} ->
          printf "live data in heap capset %d: %d bytes" heapCapset liveBytes
        HeapInfoGHC{..} ->
          printf "heap stats for heap capset %d: generations %d, %d bytes max heap size, %d bytes alloc area size, %d bytes mblock size, %d bytes block size" heapCapset gens maxHeapSize allocAreaSize mblockSize blockSize
        CapCreate{cap} ->
          printf "created cap %d" cap
        CapDelete{cap} ->
          printf "deleted cap %d" cap
        CapDisable{cap} ->
          printf "disabled cap %d" cap
        CapEnable{cap} ->
          printf "enabled cap %d" cap
        Message msg ->
          msg
        UserMessage msg ->
          msg
        UserMarker markername ->
          printf "marker: %s" markername
        CapsetCreate cs ct ->
          printf "created capset %d of type %s" cs (show ct)
        CapsetDelete cs ->
          printf "deleted capset %d" cs
        CapsetAssignCap cs cp ->
          printf "assigned cap %d to capset %d" cp cs
        CapsetRemoveCap cs cp ->
          printf "removed cap %d from capset %d" cp cs
        OsProcessPid cs pid ->
          printf "capset %d: pid %d" cs pid
        OsProcessParentPid cs ppid ->
          printf "capset %d: parent pid %d" cs ppid
        WallClockTime cs sec nsec ->
          printf "capset %d: wall clock time %ds %dns (unix epoch)" cs sec nsec
        RtsIdentifier cs i ->
          printf "capset %d: RTS version \"%s\"" cs i
        ProgramArgs cs args ->
          printf "capset %d: args: %s" cs (show args)
        ProgramEnv cs env ->
          printf "capset %d: env: %s" cs (show env)
        UnknownEvent n ->
          printf "Unknown event type %d" n
        InternString str sId ->
          printf "Interned string: \"%s\" with id %d" str sId
        -- events for the parallel RTS
        Version version ->
          printf "compiler version is %s" version
        ProgramInvocation  commandline ->
          printf "program invocation: %s" commandline
        EdenStartReceive ->
          printf "starting to receive"
        EdenEndReceive ->
          printf "stop receiving"
        CreateProcess  process ->
          printf "creating process %d" process
        KillProcess process ->
          printf "killing process %d" process
        AssignThreadToProcess thread process ->
          printf "assigning thread %d to process %d" thread process
        CreateMachine machine realtime ->
          printf "creating machine %d at %d" machine realtime
        KillMachine machine ->
          printf "killing machine %d" machine
        SendMessage mesTag senderProcess senderThread
          receiverMachine receiverProcess receiverInport ->
            printf "sending message with tag %s from process %d, thread %d to machine %d, process %d on inport %d"
            (show mesTag) senderProcess senderThread receiverMachine receiverProcess receiverInport
        ReceiveMessage mesTag receiverProcess receiverInport
          senderMachine senderProcess senderThread messageSize ->
            printf "receiving message with tag %s at process %d, inport %d from machine %d, process %d, thread %d with size %d"
            (show mesTag) receiverProcess receiverInport
            senderMachine senderProcess senderThread messageSize
        SendReceiveLocalMessage mesTag senderProcess senderThread
          receiverProcess receiverInport ->
            printf "sending/receiving message with tag %s from process %d, thread %d to process %d on inport %d"
            (show mesTag) senderProcess senderThread receiverProcess receiverInport
        MerStartParConjunction dyn_id static_id ->
          printf "Start a parallel conjunction 0x%x, static_id: %d" dyn_id static_id
        MerEndParConjunction dyn_id ->
          printf "End par conjunction: 0x%x" dyn_id
        MerEndParConjunct dyn_id ->
          printf "End par conjunct: 0x%x" dyn_id
        MerCreateSpark dyn_id spark_id ->
          printf "Create spark for conjunction: 0x%x spark: 0x%x" dyn_id spark_id
        MerFutureCreate future_id name_id ->
          printf "Create future 0x%x named %d" future_id name_id
        MerFutureWaitNosuspend future_id ->
          printf "Wait didn't suspend for future: 0x%x" future_id
        MerFutureWaitSuspended future_id ->
          printf "Wait suspended on future: 0x%x" future_id
        MerFutureSignal future_id ->
          printf "Signaled future 0x%x" future_id
        MerLookingForGlobalThread ->
          "Looking for global thread to resume"
        MerWorkStealing ->
          "Trying to steal a spark"
        MerLookingForLocalSpark ->
          "Looking for a local spark to execute"
        MerReleaseThread thread_id ->
          printf "Releasing thread %d to the free pool" thread_id
        MerCapSleeping ->
          "Capability going to sleep"
        MerCallingMain ->
          "About to call the program entry point"
        PerfName{perfNum, name} ->
          printf "perf event %d named \"%s\"" perfNum name
        PerfCounter{perfNum, tid, period} ->
          printf "perf event counter %d incremented by %d in OS thread %d"
                 perfNum (period + 1) (kernelThreadId tid)
        PerfTracepoint{perfNum, tid} ->
          printf "perf event tracepoint %d reached in OS thread %d"
                 perfNum (kernelThreadId tid)

showThreadStopStatus :: ThreadStopStatus -> String
showThreadStopStatus HeapOverflow   = "heap overflow"
showThreadStopStatus StackOverflow  = "stack overflow"
showThreadStopStatus ThreadYielding = "thread yielding"
showThreadStopStatus ThreadBlocked  = "thread blocked"
showThreadStopStatus ThreadFinished = "thread finished"
showThreadStopStatus ForeignCall    = "making a foreign call"
showThreadStopStatus BlockedOnMVar  = "blocked on an MVar"
showThreadStopStatus BlockedOnMVarRead = "blocked reading an MVar"
showThreadStopStatus BlockedOnBlackHole = "blocked on a black hole"
showThreadStopStatus BlockedOnRead = "blocked on I/O read"
showThreadStopStatus BlockedOnWrite = "blocked on I/O write"
showThreadStopStatus BlockedOnDelay = "blocked on threadDelay"
showThreadStopStatus BlockedOnSTM = "blocked in STM retry"
showThreadStopStatus BlockedOnDoProc = "blocked on asyncDoProc"
showThreadStopStatus BlockedOnCCall = "blocked in a foreign call"
showThreadStopStatus BlockedOnCCall_NoUnblockExc = "blocked in a foreign call"
showThreadStopStatus BlockedOnMsgThrowTo = "blocked in throwTo"
showThreadStopStatus ThreadMigrating = "thread migrating"
showThreadStopStatus BlockedOnMsgGlobalise = "waiting for data to be globalised"
showThreadStopStatus (BlockedOnBlackHoleOwnedBy target) =
          "blocked on black hole owned by thread " ++ show target
showThreadStopStatus NoStatus = "No stop thread status"

ppEventLog :: EventLog -> String
ppEventLog (EventLog (Header ets) (Data es)) = unlines $ concat
    [ ["Event Types:"]
    , map ppEventType ets
    , [""] -- newline
    , ["Events:"]
    , map (ppEvent imap) sorted
    , [""] ] -- extra trailing newline
 where
    imap = buildEventTypeMap ets
    sorted = sortEvents es

ppEventType :: EventType -> String
ppEventType (EventType num dsc msz) = printf "%4d: %s (size %s)" num dsc
   (case msz of Nothing -> "variable"; Just x -> show x)

-- | Pretty prints an 'Event', with clean handling for 'UnknownEvent'
ppEvent :: IntMap EventType -> Event -> String
ppEvent imap (Event {evTime = t, evSpec = spc, evCap = cap}) =
  printf "%9d: " t ++
  (case cap of
    Nothing -> ""
    Just c  -> printf "cap %d: " c) ++
  case spc of
    UnknownEvent{ ref=ref } ->
      printf (desc (fromJust (M.lookup (fromIntegral ref) imap)))
    _ -> showEventInfo spc

-- | Pretty prints an 'Event'. Cannot identify 'UnknownEvent's but has a
-- simple type signature
ppEvent' :: Event -> String
ppEvent' (Event t spc evCap) =
  printf "%9d: " t ++
  (case evCap of
    Nothing -> ""
    Just c  -> printf "cap %d: " c) ++
  case spc of
    UnknownEvent{ ref=ref } ->
      printf "Unknown Event (ref: %d)" ref
    _ -> showEventInfo spc
type PutEvents a = PutM a

putE :: Binary a => a -> PutEvents ()
putE = put

putType :: EventTypeNum -> PutEvents ()
putType = putE

putCap :: Int -> PutEvents ()
putCap c = putE (fromIntegral c :: CapNo)

putMarker :: Word32 -> PutEvents ()
putMarker = putE

putEStr :: String -> PutEvents ()
putEStr = mapM_ putE

putEventLog :: EventLog -> PutEvents ()
putEventLog (EventLog hdr es) = do
    putHeader hdr
    putData es

putHeader :: Header -> PutEvents ()
putHeader (Header ets) = do
    putMarker EVENT_HEADER_BEGIN
    putMarker EVENT_HET_BEGIN
    mapM_ putEventType ets
    putMarker EVENT_HET_END
    putMarker EVENT_HEADER_END
 where
    putEventType (EventType n d msz) = do
        putMarker EVENT_ET_BEGIN
        putType n
        putE $ fromMaybe 0xffff msz
        putE (fromIntegral $ length d :: EventTypeDescLen)
        mapM_ put d
        -- the event type header allows for extra data, which we don't use:
        putE (0 :: Word32)
        putMarker EVENT_ET_END

putData :: Data -> PutEvents ()
putData (Data es) = do
    putMarker EVENT_DATA_BEGIN -- Word32
    mapM_ putEvent es
    putType EVENT_DATA_END -- Word16

eventTypeNum :: EventInfo -> EventTypeNum
eventTypeNum e = case e of
    CreateThread {} -> EVENT_CREATE_THREAD
    RunThread {} -> EVENT_RUN_THREAD
    StopThread {} -> EVENT_STOP_THREAD
    ThreadRunnable {} -> EVENT_THREAD_RUNNABLE
    MigrateThread {} -> EVENT_MIGRATE_THREAD
    Shutdown {} -> EVENT_SHUTDOWN
    WakeupThread {} -> EVENT_THREAD_WAKEUP
    ThreadLabel {}  -> EVENT_THREAD_LABEL
    StartGC {} -> EVENT_GC_START
    EndGC {} -> EVENT_GC_END
    GlobalSyncGC {} -> EVENT_GC_GLOBAL_SYNC
    RequestSeqGC {} -> EVENT_REQUEST_SEQ_GC
    RequestParGC {} -> EVENT_REQUEST_PAR_GC
    CreateSparkThread {} -> EVENT_CREATE_SPARK_THREAD
    SparkCounters {} -> EVENT_SPARK_COUNTERS
    SparkCreate   {} -> EVENT_SPARK_CREATE
    SparkDud      {} -> EVENT_SPARK_DUD
    SparkOverflow {} -> EVENT_SPARK_OVERFLOW
    SparkRun      {} -> EVENT_SPARK_RUN
    SparkSteal    {} -> EVENT_SPARK_STEAL
    SparkFizzle   {} -> EVENT_SPARK_FIZZLE
    SparkGC       {} -> EVENT_SPARK_GC
    TaskCreate  {} -> EVENT_TASK_CREATE
    TaskMigrate {} -> EVENT_TASK_MIGRATE
    TaskDelete  {} -> EVENT_TASK_DELETE
    Message {} -> EVENT_LOG_MSG
    Startup {} -> EVENT_STARTUP
    EventBlock {} -> EVENT_BLOCK_MARKER
    UserMessage {} -> EVENT_USER_MSG
    UserMarker  {} -> EVENT_USER_MARKER
    GCIdle {} -> EVENT_GC_IDLE
    GCWork {} -> EVENT_GC_WORK
    GCDone {} -> EVENT_GC_DONE
    GCStatsGHC{} -> EVENT_GC_STATS_GHC
    HeapAllocated{} -> EVENT_HEAP_ALLOCATED
    HeapSize{} -> EVENT_HEAP_SIZE
    HeapLive{} -> EVENT_HEAP_LIVE
    HeapInfoGHC{} -> EVENT_HEAP_INFO_GHC
    CapCreate{} -> EVENT_CAP_CREATE
    CapDelete{} -> EVENT_CAP_DELETE
    CapDisable{} -> EVENT_CAP_DISABLE
    CapEnable{} -> EVENT_CAP_ENABLE
    CapsetCreate {} -> EVENT_CAPSET_CREATE
    CapsetDelete {} -> EVENT_CAPSET_DELETE
    CapsetAssignCap {} -> EVENT_CAPSET_ASSIGN_CAP
    CapsetRemoveCap {} -> EVENT_CAPSET_REMOVE_CAP
    RtsIdentifier {} -> EVENT_RTS_IDENTIFIER
    ProgramArgs {} -> EVENT_PROGRAM_ARGS
    ProgramEnv {} -> EVENT_PROGRAM_ENV
    OsProcessPid {} -> EVENT_OSPROCESS_PID
    OsProcessParentPid{} -> EVENT_OSPROCESS_PPID
    WallClockTime{} -> EVENT_WALL_CLOCK_TIME
    UnknownEvent {} -> error "eventTypeNum UnknownEvent"
    InternString {} -> EVENT_INTERN_STRING
    Version {} -> EVENT_VERSION
    ProgramInvocation {} -> EVENT_PROGRAM_INVOCATION
    EdenStartReceive {} -> EVENT_EDEN_START_RECEIVE
    EdenEndReceive {} -> EVENT_EDEN_END_RECEIVE
    CreateProcess {} -> EVENT_CREATE_PROCESS
    KillProcess {} -> EVENT_KILL_PROCESS
    AssignThreadToProcess {} -> EVENT_ASSIGN_THREAD_TO_PROCESS
    CreateMachine {} -> EVENT_CREATE_MACHINE
    KillMachine {} -> EVENT_KILL_MACHINE
    SendMessage {} -> EVENT_SEND_MESSAGE
    ReceiveMessage {} -> EVENT_RECEIVE_MESSAGE
    SendReceiveLocalMessage {} -> EVENT_SEND_RECEIVE_LOCAL_MESSAGE
    MerStartParConjunction {} -> EVENT_MER_START_PAR_CONJUNCTION
    MerEndParConjunction _ -> EVENT_MER_STOP_PAR_CONJUNCTION
    MerEndParConjunct _ -> EVENT_MER_STOP_PAR_CONJUNCT
    MerCreateSpark {} -> EVENT_MER_CREATE_SPARK
    MerFutureCreate {} -> EVENT_MER_FUT_CREATE
    MerFutureWaitNosuspend _ -> EVENT_MER_FUT_WAIT_NOSUSPEND
    MerFutureWaitSuspended _ -> EVENT_MER_FUT_WAIT_SUSPENDED
    MerFutureSignal _ -> EVENT_MER_FUT_SIGNAL
    MerLookingForGlobalThread -> EVENT_MER_LOOKING_FOR_GLOBAL_CONTEXT
    MerWorkStealing -> EVENT_MER_WORK_STEALING
    MerLookingForLocalSpark -> EVENT_MER_LOOKING_FOR_LOCAL_SPARK
    MerReleaseThread _ -> EVENT_MER_RELEASE_CONTEXT
    MerCapSleeping -> EVENT_MER_ENGINE_SLEEPING
    MerCallingMain -> EVENT_MER_CALLING_MAIN
    PerfName       {} -> nEVENT_PERF_NAME
    PerfCounter    {} -> nEVENT_PERF_COUNTER
    PerfTracepoint {} -> nEVENT_PERF_TRACEPOINT

nEVENT_PERF_NAME, nEVENT_PERF_COUNTER, nEVENT_PERF_TRACEPOINT :: EventTypeNum
nEVENT_PERF_NAME = EVENT_PERF_NAME
nEVENT_PERF_COUNTER = EVENT_PERF_COUNTER
nEVENT_PERF_TRACEPOINT = EVENT_PERF_TRACEPOINT

putEvent :: Event -> PutEvents ()
putEvent (Event {evTime = t , evSpec = spc}) = do
    putType (eventTypeNum spc)
    put t
    putEventSpec spc

putEventSpec :: EventInfo -> PutEvents ()
putEventSpec (Startup caps) = do
    putCap (fromIntegral caps)

putEventSpec (EventBlock end cap sz) = do
    putE (fromIntegral (sz+24) :: BlockSize)
    putE end
    putE (fromIntegral cap :: CapNo)

putEventSpec (CreateThread t) =
    putE t

putEventSpec (RunThread t) =
    putE t

-- here we assume that ThreadStopStatus fromEnum matches the definitions in
-- EventLogFormat.h
-- The standard encoding is used here, which is wrong for eventlogs
-- produced by GHC-7.8.2 ([Stop status in GHC-7.8.2] in EventTypes.hs
putEventSpec (StopThread t s) = do
    putE t
    putE $ case s of
            NoStatus -> 0 :: Word16
            HeapOverflow -> 1
            StackOverflow -> 2
            ThreadYielding -> 3
            ThreadBlocked -> 4
            ThreadFinished -> 5
            ForeignCall -> 6
            BlockedOnMVar -> 7
            BlockedOnMVarRead -> 20 -- since GHC-7.8.3
            BlockedOnBlackHole -> 8
            BlockedOnBlackHoleOwnedBy _ -> 8
            BlockedOnRead -> 9
            BlockedOnWrite -> 10
            BlockedOnDelay -> 11
            BlockedOnSTM -> 12
            BlockedOnDoProc -> 13
            BlockedOnCCall -> 14
            BlockedOnCCall_NoUnblockExc -> 15
            BlockedOnMsgThrowTo -> 16
            ThreadMigrating -> 17
            BlockedOnMsgGlobalise -> 18
    putE $ case s of
            BlockedOnBlackHoleOwnedBy i -> i
            _                           -> 0

putEventSpec (ThreadRunnable t) =
    putE t

putEventSpec (MigrateThread t c) = do
    putE t
    putCap c

putEventSpec (CreateSparkThread t) =
    putE t

putEventSpec (SparkCounters crt dud ovf cnv fiz gcd rem) = do
    putE crt
    putE dud
    putE ovf
    putE cnv
    -- Warning: order of fiz and gcd reversed!
    putE gcd
    putE fiz
    putE rem

putEventSpec SparkCreate =
    return ()

putEventSpec SparkDud =
    return ()

putEventSpec SparkOverflow =
    return ()

putEventSpec SparkRun =
    return ()

putEventSpec (SparkSteal c) =
    putCap c

putEventSpec SparkFizzle =
    return ()

putEventSpec SparkGC =
    return ()

putEventSpec (WakeupThread t c) = do
    putE t
    putCap c

putEventSpec (ThreadLabel t l) = do
    putE (fromIntegral (length l) + sz_tid :: Word16)
    putE t
    putEStr l

putEventSpec Shutdown =
    return ()

putEventSpec RequestSeqGC =
    return ()

putEventSpec RequestParGC =
    return ()

putEventSpec StartGC =
    return ()

putEventSpec GCWork =
    return ()

putEventSpec GCIdle =
    return ()

putEventSpec GCDone =
    return ()

putEventSpec EndGC =
    return ()

putEventSpec GlobalSyncGC =
    return ()

putEventSpec (TaskCreate taskId cap tid) = do
    putE taskId
    putCap cap
    putE tid

putEventSpec (TaskMigrate taskId cap new_cap) = do
    putE taskId
    putCap cap
    putCap new_cap

putEventSpec (TaskDelete taskId) =
    putE taskId

putEventSpec GCStatsGHC{..} = do
    putE heapCapset
    putE (fromIntegral gen :: Word16)
    putE copied
    putE slop
    putE frag
    putE (fromIntegral parNThreads :: Word32)
    putE parMaxCopied
    putE parTotCopied

putEventSpec HeapAllocated{..} = do
    putE heapCapset
    putE allocBytes

putEventSpec HeapSize{..} = do
    putE heapCapset
    putE sizeBytes

putEventSpec HeapLive{..} = do
    putE heapCapset
    putE liveBytes

putEventSpec HeapInfoGHC{..} = do
    putE heapCapset
    putE (fromIntegral gens :: Word16)
    putE maxHeapSize
    putE allocAreaSize
    putE mblockSize
    putE blockSize

putEventSpec CapCreate{cap} =
    putCap cap

putEventSpec CapDelete{cap} =
    putCap cap

putEventSpec CapDisable{cap} =
    putCap cap

putEventSpec CapEnable{cap} =
    putCap cap

putEventSpec (CapsetCreate cs ct) = do
    putE cs
    putE $ case ct of
            CapsetCustom -> 1 :: Word16
            CapsetOsProcess -> 2
            CapsetClockDomain -> 3
            CapsetUnknown -> 0

putEventSpec (CapsetDelete cs) =
    putE cs

putEventSpec (CapsetAssignCap cs cp) = do
    putE cs
    putCap cp

putEventSpec (CapsetRemoveCap cs cp) = do
    putE cs
    putCap cp

putEventSpec (RtsIdentifier cs rts) = do
    putE (fromIntegral (length rts) + sz_capset :: Word16)
    putE cs
    putEStr rts

putEventSpec (ProgramArgs cs as) = do
    let as' = unsep as
    putE (fromIntegral (length as') + sz_capset :: Word16)
    putE cs
    mapM_ putE as'

putEventSpec (ProgramEnv cs es) = do
    let es' = unsep es
    putE (fromIntegral (length es') + sz_capset :: Word16)
    putE cs
    mapM_ putE es'

putEventSpec (OsProcessPid cs pid) = do
    putE cs
    putE pid

putEventSpec (OsProcessParentPid cs ppid) = do
    putE cs
    putE ppid

putEventSpec (WallClockTime cs sec nsec) = do
    putE cs
    putE sec
    putE nsec

putEventSpec (Message s) = do
    putE (fromIntegral (length s) :: Word16)
    mapM_ putE s

putEventSpec (UserMessage s) = do
    putE (fromIntegral (length s) :: Word16)
    mapM_ putE s

putEventSpec (UserMarker s) = do
    putE (fromIntegral (length s) :: Word16)
    mapM_ putE s

putEventSpec (UnknownEvent {}) = error "putEventSpec UnknownEvent"

putEventSpec (InternString str id) = do
    putE len
    mapM_ putE str
    putE id
  where len = (fromIntegral (length str) :: Word16) + sz_string_id

putEventSpec (Version s) = do
    putE (fromIntegral (length s) :: Word16)
    mapM_ putE s

putEventSpec (ProgramInvocation s) = do
    putE (fromIntegral (length s) :: Word16)
    mapM_ putE s

putEventSpec ( EdenStartReceive ) = return ()

putEventSpec ( EdenEndReceive ) = return ()

putEventSpec ( CreateProcess  process ) = do
    putE process

putEventSpec ( KillProcess process ) = do
    putE process

putEventSpec ( AssignThreadToProcess thread process ) = do
    putE thread
    putE process

putEventSpec ( CreateMachine machine realtime ) = do
    putE machine
    putE realtime

putEventSpec ( KillMachine machine ) = do
    putE machine

putEventSpec ( SendMessage mesTag senderProcess senderThread
                 receiverMachine receiverProcess receiverInport ) = do
    putE (fromMsgTag mesTag)
    putE senderProcess
    putE senderThread
    putE receiverMachine
    putE receiverProcess
    putE receiverInport

putEventSpec ( ReceiveMessage mesTag receiverProcess receiverInport
                 senderMachine senderProcess senderThread messageSize ) = do
    putE (fromMsgTag mesTag)
    putE receiverProcess
    putE receiverInport
    putE senderMachine
    putE senderProcess
    putE senderThread
    putE messageSize

putEventSpec ( SendReceiveLocalMessage mesTag senderProcess senderThread
                 receiverProcess receiverInport ) = do
    putE (fromMsgTag mesTag)
    putE senderProcess
    putE senderThread
    putE receiverProcess
    putE receiverInport

putEventSpec (MerStartParConjunction dyn_id static_id) = do
    putE dyn_id
    putE static_id

putEventSpec (MerEndParConjunction dyn_id) =
    putE dyn_id

putEventSpec (MerEndParConjunct dyn_id) =
    putE dyn_id

putEventSpec (MerCreateSpark dyn_id spark_id) = do
    putE dyn_id
    putE spark_id

putEventSpec (MerFutureCreate future_id name_id) = do
    putE future_id
    putE name_id

putEventSpec (MerFutureWaitNosuspend future_id) =
    putE future_id

putEventSpec (MerFutureWaitSuspended future_id) =
    putE future_id

putEventSpec (MerFutureSignal future_id) =
    putE future_id

putEventSpec MerLookingForGlobalThread = return ()
putEventSpec MerWorkStealing = return ()
putEventSpec MerLookingForLocalSpark = return ()

putEventSpec (MerReleaseThread thread_id) =
    putE thread_id

putEventSpec MerCapSleeping = return ()
putEventSpec MerCallingMain = return ()

putEventSpec PerfName{..} = do
    putE (fromIntegral (length name) + sz_perf_num :: Word16)
    putE perfNum
    mapM_ putE name

putEventSpec PerfCounter{..} = do
    putE perfNum
    putE tid
    putE period

putEventSpec PerfTracepoint{..} = do
    putE perfNum
    putE tid

-- [] == []
-- [x] == x\0
-- [x, y, z] == x\0y\0
unsep :: [String] -> String
unsep = concatMap (++"\0") -- not the most efficient, but should be ok

splitNull :: String -> [String]
splitNull [] = []
splitNull xs = case span (/= '\0') xs of
                (x, xs') -> x : splitNull (drop 1 xs')
