-- Created by Nicholas Bisset 2025
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RankNTypes #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}
{-# HLINT ignore "Use newtype instead of data" #-}
{-# HLINT ignore "Use join" #-}

module Threading (
  safePrint,
  emit,
  AwaitBatch,
  newAwaitBatch,
  awaitBatched,
  WorkerPool(..),
  createThreadPool,
  submit,
  await,
  wrapped,
  submitTask,
  submitTaskAsync,
  submitAll,
  submitAllAsync,
  submitNested,
  passThrough,
  passAll,
  passNested,
  passThroughAsync,
  passAllAsync,
  passThroughAsyncIndexed,
  passAllAsyncIndexed
) where

import Control.Concurrent.STM (
  atomically,
  modifyTVar',
  newEmptyTMVar,
  newTQueueIO,
  newTVarIO,
  isFullTBQueue,
  putTMVar,
  readTMVar,
  readTQueue,
  readTVar,
  writeTQueue,
  TQueue,
  TMVar,
  TVar,
  writeTBQueue,
  TBQueue )
import Control.Concurrent
    ( MVar,
      ThreadId,
      forkIO,
      newEmptyMVar,
      withMVar,
      newMVar,
      putMVar,
      readMVar )
import Control.Monad (forever, forM, join, unless, void)
import System.IO.Unsafe (unsafePerformIO)
import System.IO (hFlush, stdout)
import Control.DeepSeq (force)
import Control.Exception
    (SomeException, evaluate, handle, mask, try, throwIO)
import qualified Data.Map.Strict as Map

-- | Registry of currently running actions. Callers using the same key share
-- the result of one action; completed actions are not cached.
newtype AwaitBatch key value = AwaitBatch
  (TVar (Map.Map key (TMVar (Either SomeException value))))

newAwaitBatch :: IO (AwaitBatch key value)
newAwaitBatch = AwaitBatch <$> newTVarIO Map.empty

-- | Run at most one action for a key at a time. The first caller is the leader
-- and every concurrent follower awaits the same broadcast result. Exceptions
-- are broadcast too, and the key is always removed so a later call can retry.
awaitBatched :: Ord key => AwaitBatch key value -> key -> IO value -> IO value
awaitBatched (AwaitBatch active) key action = mask $ \restore -> do
  (isLeader, resultVar) <- atomically $ do
    batches <- readTVar active
    case Map.lookup key batches of
      Just existing -> pure (False, existing)
      Nothing -> do
        created <- newEmptyTMVar
        modifyTVar' active (Map.insert key created)
        pure (True, created)

  if isLeader
    then do
      outcome <- try (restore action)
      atomically $ do
        putTMVar resultVar outcome
        modifyTVar' active (Map.delete key)
      either throwIO pure outcome
    else do
      outcome <- restore (atomically (readTMVar resultVar))
      either throwIO pure outcome

-- ThreadPool abstraction
data WorkerPool = WorkerPool
  { numWorkers  :: Int,
    __workers   :: [ThreadId],
    __name      :: String,
    __taskQueue :: TQueue (Int -> IO ()) }

-- Shared globally
stdoutLock :: MVar ()
stdoutLock = unsafePerformIO $ newMVar ()
{-# NOINLINE stdoutLock #-}

safePrint :: String -> IO ()
safePrint msg = withMVar stdoutLock $ \_ -> do
  putStrLn msg
  hFlush stdout

-- | Emits messages for frontend/notifier simulation
emit :: TBQueue String -> String -> IO ()
emit q msg = do
  res <- evaluate (force msg)
  -- Progress updates must never stall the underlying repository job when a
  -- client is slow or disconnected. The final value travels separately.
  atomically $ do
    full <- isFullTBQueue q
    unless full $ writeTBQueue q res

await :: IO (IO a) -> IO a
await = join

wrapped :: a -> IO a
wrapped = pure

-- Create a thread pool with N worker threads
createThreadPool :: Int -> String -> IO WorkerPool
createThreadPool n name = do
  let workerCount = max 1 n
  q <- newTQueueIO
  tids <- forM [0 .. workerCount - 1] $ \i ->
    forkIO $ workerLoop i q
  pure $ WorkerPool workerCount tids name q

-- Worker loop that never dies: catches exceptions from tasks and ignores them,
-- then continues looping.
workerLoop :: Int -> TQueue (Int -> IO ()) -> IO ()
workerLoop idx q = forever $ do
  task <- atomically $ readTQueue q
  handle (\(_ :: SomeException) -> pure ()) (void $ task idx)

-- Submit a task to the pool, returning an IO that produces the result.
-- The returned IO, when executed, will re-throw the exception
-- if the task failed, or return the successful value.
submitIndexed :: WorkerPool -> (Int -> IO a) -> IO (IO a)
submitIndexed (WorkerPool _ _ _ queue) action = do
  resultVar <- newEmptyMVar :: IO (MVar (Either SomeException a))
  -- Mask the publication gap so cancellation can never leave an empty future.
  let wrappedAction idx = mask $ \restore -> do
        outcome <- try (restore (action idx >>= evaluate))
        putMVar resultVar outcome
  atomically $ writeTQueue queue wrappedAction
  -- readMVar makes a submitted future safe to await more than once.
  pure $ do
    outcome <- readMVar resultVar
    case outcome of
      Left ex -> throwIO ex
      Right value -> pure value

-- Fallback version: ignores index
submit :: WorkerPool -> IO a -> IO (IO a)
submit pool action = submitIndexed pool (const action)

-- Submit a pure function to run in the pool (returns future)
submitTask :: WorkerPool -> (a -> b) -> a -> IO (IO b)
submitTask pool f x = submit pool (return (f x))

-- Submit a pure function to run in the pool 
submitTaskAsync :: WorkerPool -> (a -> IO b) -> a -> IO (IO b)
submitTaskAsync pool f x = submit pool (f x)

-- Submit a collection of inputs to run in parallel (returns futures)
submitAll :: WorkerPool -> (a -> b) -> [a] -> IO [IO b]
submitAll pool f = mapM (submitTask pool f)

-- Submit a collection of inputs to run in parallel (returns futures)
submitAllAsync :: WorkerPool -> (a -> IO b) -> [a] -> IO [IO b]
submitAllAsync pool f = mapM (submitTaskAsync pool f)

submitNested :: WorkerPool -> (a -> b) -> [[a]] -> IO (IO [[b]])
submitNested pool f nested = do
  -- Submit all tasks (flattened), keeping nested structure
  promises <- mapM (submitAll pool f) nested -- [[IO b]]
  -- Turn [[IO b]] into IO [[b]]
  return $ mapM sequence promises

-- pass two functions to be executed through thread pools, 
-- ensuring the result obtained by the computation from the first pool is then
-- used in the second computation in the second pool as soon as it is ready
passThrough :: WorkerPool -> WorkerPool -> (a -> b) -> (b -> c) -> a -> IO (IO c)
passThrough p1 p2 f1 f2 x = do
  firstFuture <- submitTask p1 f1 x    -- IO (IO b)
  innerResult <- firstFuture           -- IO b
  submitTask p2 f2 innerResult         -- IO (IO c)

passAll :: WorkerPool -> WorkerPool -> (a -> b) -> (b -> c) -> [a] -> IO [c]
passAll p1 p2 f1 f2 xs = do
  mapM (passThrough p1 p2 f1 f2) xs >>= sequence

passNested :: WorkerPool -> WorkerPool -> (a -> b) -> (b -> c) -> [[a]] -> IO [[c]]
passNested p1 p2 f1 f2 =
  mapM (passAll p1 p2 f1 f2)

passThroughAsync :: WorkerPool -> WorkerPool -> (a -> IO b) -> (b -> IO c) -> a -> IO (IO c)
passThroughAsync p1 p2 f1 f2 x = do
  futureB <- submit p1 (f1 x)            -- IO (IO b)
  pure $ do
    b <- futureB                         -- IO b
    submit p2 (f2 b) >>= id              -- IO c

passAllAsync :: WorkerPool -> WorkerPool -> (a -> IO b) -> (b -> IO c) -> [a] -> IO [c]
passAllAsync p1 p2 f1 f2 xs = do
  futures <- mapM (passThroughAsync p1 p2 f1 f2) xs  -- [IO c]
  sequence futures  -- IO [c]

-- pass through indexed variants
passThroughAsyncIndexed :: WorkerPool -> WorkerPool -> (a -> Int -> IO b) -> (b -> IO c) -> a -> IO (IO c)
passThroughAsyncIndexed p1 p2 f1 f2 x = do
  futureB <- submitIndexed p1 (f1 x)     -- IO (IO b)
  pure $ do
    b <- futureB                         -- IO b
    submit p2 (f2 b) >>= id              -- IO c

passAllAsyncIndexed :: WorkerPool -> WorkerPool -> (a -> Int -> IO b) -> (b -> IO c) -> [a] -> IO [c]
passAllAsyncIndexed p1 p2 f1 f2 xs = do
  futures <- mapM (passThroughAsyncIndexed p1 p2 f1 f2) xs  -- [IO c]
  sequence futures  -- IO [c]

