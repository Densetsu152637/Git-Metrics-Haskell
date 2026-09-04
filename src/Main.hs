-- Created by Nicholas Bisset 2025
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE CPP #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}
{-# HLINT ignore "Use camelCase" #-}

module Main (main) where

import System.Environment (setEnv, unsetEnv)
import GHC.Conc (getNumProcessors, setNumCapabilities)

import Network.Wai.Handler.WebSockets (websocketsOr)
import Network.WebSockets.Connection (defaultConnectionOptions)
import Network.Wai.Handler.Warp
  ( runSettings, defaultSettings, setPort, setHost, Settings )

#if !defined(mingw32_HOST_OS)
import Control.Concurrent.Async (concurrently_)
import Control.Exception (bracket)
import Network.Socket
  ( socket, bind, listen, Socket, SockAddr(SockAddrUnix)
  , Family(AF_UNIX), SocketType(Stream)
  , close
  )
import Network.Wai.Handler.Warp (runSettingsSocket)
#endif

import Api
import Process
import Threading
import Security (validateSecurityConfiguration)

cleanEnvironment :: IO ()
cleanEnvironment = do
    -- remove problematic variables
    unsetEnv "GIT_ASKPASS"
    unsetEnv "GCM_INTERACTIVE"

    -- inject variables to disable prompts
    setEnv "GIT_TERMINAL_PROMPT" "0"
    setEnv "SSH_AUTH_SOCK" "\\.\\pipe\\ssh-auth-sock"

    pure ()

#if !defined(mingw32_HOST_OS)
socketPath :: FilePath
socketPath = "/tmp/haskell-ipc.sock"
#endif

-- | Initialize the runtime to use all logical cores
initializeRuntime :: IO ()
initializeRuntime = do
    cores <- getNumProcessors
    setNumCapabilities cores

    -- worker thread pools should be ready for use
    -- safePrint $ "number of cores available for use: " ++ show cores
    safePrint $ "number of cores available for parsingPool: " ++ show (numWorkers parsingPool)
    safePrint $ "number of cores available for commandPool: " ++ show (numWorkers commandPool)

    pure ()

main :: IO ()
main = do
    validateSecurityConfiguration
    initializeRuntime
    cleanEnvironment

    -- Enable permessage-deflate (RSV1 frames allowed)
    let opts = defaultConnectionOptions  -- no connectionCompression
    let app  = websocketsOr opts appWS appHTTP

#if defined(mingw32_HOST_OS)
    -- On Windows: only TCP
    runSettings tcpSettings app
#else
    -- On Unix: TCP + Unix socket
    bracket (setupUnixSocket socketPath) close $ \unixSock ->
        concurrently_
            (runSettings tcpSettings app)
            (runSettingsSocket defaultSettings unixSock app)
#endif

-- TCP Settings
tcpSettings :: Settings
tcpSettings = setPort 8081 $ setHost "0.0.0.0" defaultSettings

#if !defined(mingw32_HOST_OS)
-- Helper to create a Unix domain socket
setupUnixSocket :: FilePath -> IO Socket
setupUnixSocket path = do
    sock <- socket AF_UNIX Stream 0
    bind sock (SockAddrUnix path)
    listen sock 1024
    return sock
#endif
