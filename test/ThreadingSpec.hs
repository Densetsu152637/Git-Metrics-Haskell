module Main (main) where

import Control.Concurrent
  ( forkIO
  , newEmptyMVar
  , putMVar
  , readMVar
  , takeMVar
  , threadDelay
  )
import Control.Exception (SomeException, try)
import Control.Monad (forM, replicateM_, unless)
import Control.Concurrent.STM (atomically, newTBQueue, readTBQueue)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)

import Threading
  ( awaitBatched
  , createThreadPool
  , emit
  , newAwaitBatch
  , numWorkers
  , submit
  )

assert :: String -> Bool -> IO ()
assert message condition = unless condition (ioError (userError message))

testConcurrentDuplicatesShareOneAction :: IO ()
testConcurrentDuplicatesShareOneAction = do
  batch <- newAwaitBatch
  actionCount <- newIORef (0 :: Int)
  readyCount <- newIORef (0 :: Int)
  startGate <- newEmptyMVar
  actionStarted <- newEmptyMVar
  finishAction <- newEmptyMVar
  let callerCount = 32
      action = do
        atomicModifyIORef' actionCount (\n -> (n + 1, ()))
        putMVar actionStarted ()
        takeMVar finishAction
        pure (42 :: Int)
      caller = do
        atomicModifyIORef' readyCount (\n -> (n + 1, ()))
        readMVar startGate
        awaitBatched batch "same-repository" action

  results <- forM [1 .. callerCount] $ \_ -> do
    result <- newEmptyMVar
    _ <- forkIO $ caller >>= putMVar result
    pure result

  let waitUntilReady = do
        ready <- readIORef readyCount
        if ready == callerCount then pure () else threadDelay 1000 >> waitUntilReady
  waitUntilReady
  putMVar startGate ()
  takeMVar actionStarted
  -- Give every released caller time to join the in-flight batch while its
  -- leader remains blocked.
  threadDelay 100000
  putMVar finishAction ()

  values <- mapM takeMVar results
  count <- readIORef actionCount
  assert "concurrent duplicate callers did not share a result" (values == replicate callerCount 42)
  assert "duplicate action executed more than once" (count == 1)

testFailureIsSharedAndLaterCallsRetry :: IO ()
testFailureIsSharedAndLaterCallsRetry = do
  batch <- newAwaitBatch
  first <- try (awaitBatched batch "repository" (ioError (userError "failed")))
    :: IO (Either SomeException Int)
  assert "leader exception was not returned" (either (const True) (const False) first)

  value <- awaitBatched batch "repository" (pure 7)
  assert "failed batch was not removed for retry" (value == 7)

testSubmittedFutureIsReusable :: IO ()
testSubmittedFutureIsReusable = do
  pool <- createThreadPool 1 "future-test"
  future <- submit pool (pure (11 :: Int))
  first <- future
  second <- future
  assert "submitted future could not be awaited more than once" (first == 11 && second == 11)

testSubmittedExceptionIsReusable :: IO ()
testSubmittedExceptionIsReusable = do
  pool <- createThreadPool 1 "exception-test"
  future <- submit pool (ioError (userError "worker failed") :: IO Int)
  first <- try future :: IO (Either SomeException Int)
  second <- try future :: IO (Either SomeException Int)
  let failed = either (const True) (const False)
  assert "worker exception was not published to every awaiter" (failed first && failed second)

testProgressQueueDoesNotBlockWork :: IO ()
testProgressQueueDoesNotBlockWork = do
  notifier <- atomically $ newTBQueue 1
  emit notifier "first"
  emit notifier "dropped while full"
  update <- atomically $ readTBQueue notifier
  assert "progress queue did not preserve its available update" (update == "first")

testThreadPoolAlwaysHasAWorker :: IO ()
testThreadPoolAlwaysHasAWorker = do
  pool <- createThreadPool 0 "minimum-worker-test"
  assert "zero-sized pool would deadlock submitted work" (numWorkers pool == 1)

main :: IO ()
main = do
  replicateM_ 20 testConcurrentDuplicatesShareOneAction
  testFailureIsSharedAndLaterCallsRetry
  testSubmittedFutureIsReusable
  testSubmittedExceptionIsReusable
  testProgressQueueDoesNotBlockWork
  testThreadPoolAlwaysHasAWorker
  putStrLn "threading-tests: passed"
