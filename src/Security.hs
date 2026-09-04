module Security
  ( RepositoryTarget(..)
  , apiKeyAuthorized
  , configuredAllowedHosts
  , constantTimeEqual
  , repositoryAccessPath
  , validateAuthToken
  , validateRepositoryUrl
  , validateSecurityConfiguration
  ) where

import Control.Monad (unless)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Bits ((.|.), xor)
import Data.Char (isAscii, isAsciiLower, isAsciiUpper, isControl, isDigit, toLower)
import Data.List (foldl', intercalate)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as B8
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Network.URI
  ( URI(..)
  , URIAuth(..)
  , parseURI
  )
import System.Environment (lookupEnv)
import System.FilePath ((</>))

data RepositoryTarget = RepositoryTarget
  { repositoryUrl :: String
  , repositoryPath :: FilePath
  } deriving (Eq, Show)

-- | Validate a per-request HTTPS Git credential without modifying it. Tokens
-- are intentionally kept separate from repository URLs so they cannot leak via
-- Git remotes, command lines, or URL-oriented logging.
validateAuthToken :: Maybe String -> Either String (Maybe String)
validateAuthToken Nothing = Right Nothing
validateAuthToken (Just token)
  | null token = Left "auth_token must not be empty."
  | length token > 4096 = Left "auth_token is too long."
  | any (\value -> not (isAscii value) || isControl value) token =
      Left "auth_token must contain printable ASCII characters only."
  | otherwise = Right (Just token)

-- | Keep public and authenticated clones in distinct namespaces. The token is
-- represented by a SHA-256 fingerprint: stable enough for request batching and
-- path isolation without placing the credential itself on disk.
repositoryAccessPath :: Maybe String -> RepositoryTarget -> FilePath
repositoryAccessPath authToken target =
  credentialScope authToken </> repositoryPath target
  where
    credentialScope Nothing = "public"
    credentialScope (Just token) =
      "authenticated-" ++ show (hashToken token)
    hashToken token = hash (TE.encodeUtf8 (T.pack token)) :: Digest SHA256

splitOn :: Eq a => a -> [a] -> [[a]]
splitOn separator = foldr step [[]]
  where
    step value (current:rest)
      | value == separator = [] : current : rest
      | otherwise = (value : current) : rest
    step _ [] = [[]]

trim :: String -> String
trim = reverse . dropWhile (== ' ') . reverse . dropWhile (== ' ')

normaliseHost :: String -> String
normaliseHost = map toLower . trim

configuredAllowedHosts :: IO [String]
configuredAllowedHosts = do
  configured <- lookupEnv "GIT_ALLOWED_HOSTS"
  pure $ filter (not . null) $ map normaliseHost $
    splitOn ',' (maybe "github.com,gitlab.com,bitbucket.org" id configured)

validPathCharacter :: Char -> Bool
validPathCharacter value =
  isAsciiLower value || isAsciiUpper value || isDigit value || value `elem` ("-_." :: String)

validateRepositoryUrl :: [String] -> String -> Either String RepositoryTarget
validateRepositoryUrl allowedHosts rawUrl = do
  uri <- maybe (Left "Repository URL is invalid.") Right (parseURI rawUrl)
  authority <- maybe (Left "Repository URL must include a host.") Right (uriAuthority uri)
  let host = normaliseHost (uriRegName authority)
      pathSegments = filter (not . null) (splitOn '/' (uriPath uri))
      allowed = map normaliseHost allowedHosts
  unless (uriScheme uri == "https:") $
    Left "Repository URL must use HTTPS."
  unless (null (uriUserInfo authority)) $
    Left "Repository URL must not contain embedded credentials."
  unless (null (uriPort authority)) $
    Left "Repository URL must not specify a custom port."
  unless (null (uriQuery uri) && null (uriFragment uri)) $
    Left "Repository URL must not contain a query string or fragment."
  unless (host `elem` allowed) $
    Left "Repository host is not allowed."
  unless (length pathSegments >= 2) $
    Left "Repository URL must include an owner and repository."
  unless (all validSegment pathSegments) $
    Left "Repository path contains unsupported characters."

  let canonicalSegments = stripGitSuffix pathSegments
      canonicalUrl = "https://" ++ host ++ "/" ++ intercalate "/" canonicalSegments
      localPath = foldl (</>) host canonicalSegments
  pure $ RepositoryTarget canonicalUrl localPath
  where
    validSegment segment =
      segment `notElem` [".", ".."] && all validPathCharacter segment
    stripGitSuffix segments =
      case reverse segments of
        repository:rest
          | length repository > 4 && reverse (take 4 (reverse repository)) == ".git" ->
              reverse ((take (length repository - 4) repository) : rest)
        _ -> segments

constantTimeEqual :: BS.ByteString -> BS.ByteString -> Bool
constantTimeEqual expected supplied =
  BS.length expected == BS.length supplied
    && foldl' (.|.) 0 (BS.zipWith xor expected supplied) == 0

apiKeyAuthorized :: Maybe BS.ByteString -> Maybe BS.ByteString -> Bool
apiKeyAuthorized Nothing _ = True
apiKeyAuthorized (Just expected) supplied =
  maybe False (constantTimeEqual expected) supplied

validateSecurityConfiguration :: IO ()
validateSecurityConfiguration = do
  environment <- lookupEnv "NODE_ENV"
  apiToken <- lookupEnv "GIT_API_TOKEN"
  hosts <- configuredAllowedHosts
  unless (not (null hosts)) $
    ioError (userError "GIT_ALLOWED_HOSTS must contain at least one host.")
  case (environment, apiToken) of
    (Just "production", Just token) | BS.length (B8.pack token) >= 32 -> pure ()
    (Just "production", _) ->
      ioError (userError "GIT_API_TOKEN must be at least 32 bytes in production.")
    _ -> pure ()
