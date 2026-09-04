-- Created by Nicholas Bisset 2025
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}

module Api (
  appWS,
  appHTTP,
  fallback
) where

import Network.Wai
import qualified Network.WebSockets as WS

import Network.HTTP.Types
  ( status200
  , status400
  , status401
  , status405
  , status500
  , methodGet
  , methodPost
  , Header
  )

import Data.Aeson
import qualified Data.Text as T
import Data.Text (Text)
import Data.Char (isSpace)
import GHC.Generics
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as B8

import Control.Concurrent.STM (atomically, newTBQueue, readTBQueue)
import Control.Concurrent.Async (withAsync)
import Control.Monad (forever, void)
import System.Environment (lookupEnv)

import Process (fetchDataFrom)
import Types ()
import Threading (safePrint)
import Security (apiKeyAuthorized)

maxRequestBytes :: Int
maxRequestBytes = 8192

headersAuthorized :: [Header] -> IO Bool
headersAuthorized headers = do
  configured <- lookupEnv "GIT_API_TOKEN"
  pure $ apiKeyAuthorized (B8.pack <$> configured)
    (lookup "X-Git-Api-Key" headers)

readLimitedBody :: Request -> IO (Either Text BL.ByteString)
readLimitedBody request = go 0 []
  where
    go total chunks = do
      chunk <- getRequestBodyChunk request
      if BS.null chunk
        then pure (Right (BL.fromChunks (reverse chunks)))
        else
          let nextTotal = total + BS.length chunk
          in if nextTotal > maxRequestBytes
             then pure (Left "Request body is too large.")
             else go nextTotal (chunk : chunks)

------------------------------------------------------------
-- Incoming JSON
------------------------------------------------------------
data ClientMessage = ClientMessage
  { url :: String
  , authToken :: Maybe String
  }
  deriving (Generic)

instance FromJSON ClientMessage where
  parseJSON = withObject "ClientMessage" $ \value ->
    ClientMessage <$> value .: "url" <*> value .:? "auth_token"

encodeValue :: ToJSON a => Text -> a -> BL.ByteString
encodeValue label val = encode $ object ["type" .= label, "data" .= val]

encodeError :: Text -> BL.ByteString
encodeError msg = encode $ object ["type" .= ("error" :: Text), "message" .= msg]

trim :: String -> String
trim = f . f
  where f = reverse . dropWhile isSpace

------------------------------------------------------------
-- 📡 WebSocket Handler
------------------------------------------------------------
appWS :: WS.ServerApp
appWS pendingConn = do
  authorized <- headersAuthorized (WS.requestHeaders (WS.pendingRequest pendingConn))
  if not authorized
    then WS.rejectRequest pendingConn "Unauthorized"
    else handleAuthorizedWebSocket pendingConn

handleAuthorizedWebSocket :: WS.ServerApp
handleAuthorizedWebSocket pendingConn = do
  conn <- WS.acceptRequest pendingConn

  msg <- WS.receiveData conn
  if BS.length msg > maxRequestBytes
    then do
      WS.sendTextData conn $ encodeError "Request body is too large."
      WS.sendClose conn ("Bad input" :: Text)
    else case eitherDecode (BL.fromStrict msg) of
    Left _ -> do
      WS.sendTextData conn $ encodeError "Invalid JSON format. Expected: {\"url\": \"...\"}"
      WS.sendClose conn ("Bad input" :: Text)

    Right (ClientMessage repoUrl repositoryAuthToken) -> do
      safePrint "Processing authenticated repository request (WS)."
      notifier <- atomically $ newTBQueue 1000

      -- Stream text_update messages while job runs
      withAsync (forever $ do
          update <- atomically $ readTBQueue notifier
          WS.sendTextData conn (BL.toStrict $ encodeValue "text_update" update)
        ) $ \_ -> do

        result <- fetchDataFrom (trim repoUrl) repositoryAuthToken notifier
        case result of
          Right repoData -> WS.sendTextData conn (BL.toStrict $ encodeValue "value" repoData)
          Left errmsg    -> do
            WS.sendTextData conn (BL.toStrict $ encodeValue "text_update" errmsg)
            WS.sendTextData conn (BL.toStrict $ encodeError (T.pack ("err: " ++ errmsg)))

      WS.sendClose conn ("Done" :: Text)

------------------------------------------------------------
-- 🌐 HTTP Fallback Handler (POST only)
------------------------------------------------------------
fallback :: Application
fallback req respond =
  if requestMethod req == methodGet && pathInfo req == ["health"]
    then respond $ responseLBS status200 [("Content-Type", "application/json")] "{\"status\":\"ok\"}"
    else do
      authorized <- headersAuthorized (requestHeaders req)
      if not authorized
        then respond $ responseLBS status401 [("Content-Type", "application/json")]
              $ encodeError "Unauthorized."
        else if requestMethod req /= methodPost
          then respond $ responseLBS status405 [("Content-Type", "text/plain")] "Method Not Allowed"
          else do
            bodyResult <- readLimitedBody req
            case bodyResult of
              Left bodyError ->
                respond $ responseLBS status400 [("Content-Type", "application/json")]
                          $ encodeError bodyError
              Right body -> case eitherDecode body of
                Left _ ->
                  respond $ responseLBS status400 [("Content-Type", "application/json")]
                            $ encodeError "Invalid JSON format. Expected: {\"url\": \"...\"}"

                Right (ClientMessage repoUrl repositoryAuthToken) -> do
                  safePrint "Processing authenticated repository request (HTTP)."
                  notifier <- atomically $ newTBQueue 1000

                  -- Discard updates, but ensure worker cleaned up
                  withAsync (forever $ void (atomically (readTBQueue notifier))) $ \_ -> do
                    result <- fetchDataFrom (trim repoUrl) repositoryAuthToken notifier
                    case result of
                      Right repoData ->
                        respond $ responseLBS status200 [("Content-Type", "application/json")]
                                  $ encodeValue "value" repoData
                      Left errmsg -> do
                        respond $ responseLBS status500 [("Content-Type", "application/json")]
                                  $ encodeError (T.pack ("err: " ++ errmsg))

------------------------------------------------------------
-- Exported HTTP app
------------------------------------------------------------
appHTTP :: Application
appHTTP = fallback
