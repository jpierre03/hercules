{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE StrictData                 #-}

module Hercules.ServerEnv
  ( Env(..)
  , App(..)
  , runApp
  , runAppWithConfig
  , newEnv
  , runHerculesQueryWithConnection
  , runHerculesQueryWithConnectionSingular
  , runHydraQueryWithConnection
  , withHerculesConnection
  , withHttpManager
  , getAuthenticator
  , makeUserJWT
  , getHostAndPort
  , HerculesCipher
  ) where

import Control.Monad.Except.Extra
import Control.Monad.Log
import Control.Monad.Reader
import Crypto.Cipher.AES
import Crypto.Cipher.Types
import Crypto.Error
import Crypto.JOSE.Error
import Crypto.Random.Entropy
import Data.ByteString.Extra           as BS (readFileMaybe, writeFile, ByteString)
import Data.ByteString.Lazy            (toStrict)
import Data.List                       (find)
import Data.Maybe                      (fromMaybe)
import Data.Pool
import Data.Profunctor.Product.Default (Default)
import Data.Semigroup
import Data.String                     (fromString)
import Data.Text                       (Text, pack)
import Data.Text.Encoding              (encodeUtf8)
import Data.Time.Format
import Data.Yaml
import Database.PostgreSQL.Simple      (Connection, close, connectPostgreSQL)
import Network.HTTP.Client             as HTTP
import Network.HTTP.Client.TLS
import Opaleye                         (Query, QueryRunner, Unpackspec,
                                        runQuery, showSql)
import Say
import Servant                         (ServantErr)
import Servant.Auth.Server             (JWTSettings, defaultJWTSettings,
                                        generateKey, makeJWT)

import Hercules.Config
import Hercules.Database.Hercules.Migration
import Hercules.Log
import Hercules.OAuth.Types                 (AuthenticatorName,
                                             OAuth2Authenticator,
                                             PackedJWT (..), authenticatorName)
import Hercules.OAuth.User
import Network.Wai.Handler.Warp             (Port)

{-# ANN module ("HLint: ignore Avoid lambda" :: String) #-}

data Env = Env { envHerculesConnectionPool :: Pool Connection
               , envHydraConnectionPool    :: Pool Connection
               , envHttpManager            :: HTTP.Manager
               , envAuthenticators         :: [OAuth2Authenticator App]
               , envJWTSettings            :: JWTSettings
               , envCipher                 :: HerculesCipher
               , envPort                   :: Port
               , envHostname               :: HostName
               }

-- | The cipher Hercues uses for encrypting the github access tokens
type HerculesCipher = AES256

newtype App a = App
  { unApp :: ReaderT Env (ExceptT ServantErr (LogM (WithSeverity LogMessage) IO)) a
  }
  deriving ( Functor
           , Applicative
           , Monad
           , MonadError ServantErr
           , MonadIO
           , MonadLog (WithSeverity LogMessage)
           , MonadReader Env
           )

-- | Perform an action with a PostgreSQL connection to the Hercules DB and
-- return the result
withHerculesConnection :: (Connection -> IO a) -> App a
withHerculesConnection f = do
  connectionPool <- asks envHerculesConnectionPool
  liftIO $ withResource connectionPool f

-- | Perform an action with a PostgreSQL connection to the Hydra DB and return
-- the result
withHydraConnection :: (Connection -> IO a) -> App a
withHydraConnection f = do
  connectionPool <- asks envHydraConnectionPool
  liftIO $ withResource connectionPool f

withHttpManager :: (HTTP.Manager -> IO a) -> App a
withHttpManager f = do
  manager <- asks envHttpManager
  liftIO $ f manager

getAuthenticator :: AuthenticatorName -> App (Maybe (OAuth2Authenticator App))
getAuthenticator name =
  find ((== name) . authenticatorName) <$> asks envAuthenticators

makeUserJWT :: UserId -> App (Either Error PackedJWT)
makeUserJWT user = do
  jwtSettings <- asks envJWTSettings
  liftIO $ fmap (PackedJWT . toStrict) <$> makeJWT user jwtSettings Nothing

-- | Evaluate a query in an 'App' value
runHerculesQueryWithConnection
  :: Default QueryRunner columns haskells
  => Default Unpackspec columns columns
  => Query columns -> App [haskells]
runHerculesQueryWithConnection q = do
  logQuery q
  withHerculesConnection (\c -> runQuery c q)

-- | Evaluate a query in an 'App' value returning a singular result
runHerculesQueryWithConnectionSingular
  :: Default QueryRunner columns haskells
  => Default Unpackspec columns columns =>
     Query columns -> App (Maybe haskells)
runHerculesQueryWithConnectionSingular q =
  runHerculesQueryWithConnection q >>=
  \case
    []  -> pure Nothing
    [x] -> pure $ Just x
    _   -> do
      logError "Singular query returned multiple results"
      pure Nothing

-- | Evaluate a query in an 'App' value
runHydraQueryWithConnection
  :: Default QueryRunner columns haskells
  => Default Unpackspec columns columns
  => Query columns -> App [haskells]
runHydraQueryWithConnection q = do
  logQuery q
  withHydraConnection (\c -> runQuery c q)

logQuery
  :: Default Unpackspec columns columns
  => Query columns
  -> App ()
logQuery q =
  let s = fromMaybe "Empty query" $ showSql q
  in logDebug (fromString s)

runApp :: Env -> App a -> ExceptT ServantErr IO a
runApp env = mapExceptT runLog
           . flip runReaderT env
           . unApp
  where
    runLog :: LogM (WithSeverity LogMessage) IO a -> IO a
    runLog = (`runLoggingT` printMessage) . mapLogMessageM timestamp
    printMessage :: WithTimestamp (WithSeverity LogMessage) -> IO ()
    printMessage = print . renderWithTimestamp renderTime (renderWithSeverity render)
    renderTime = formatTime defaultTimeLocale "%b %_d %H:%M:%S"

-- | Get a pool of connections to the Hercules database. Return 'Nothing' if the
-- schema can't be updated to the correct one.
getHerculesConnection :: MonadIO m => Config -> m (Maybe (Pool Connection))
getHerculesConnection Config{..} = liftIO $ do
  herculesConnection <- createPool
    (connectPostgreSQL (encodeUtf8 configHerculesConnectionString))
    close
    4 10 4
  withResource herculesConnection (readyDatabase Quiet) >>= \case
    MigrationError s -> do
      sayErr ("Error migrating hercules database: " <> s)
      pure Nothing
    MigrationSuccess -> pure (Just herculesConnection)

-- | Load the key from the secret key file if it exists or create one.
getCipher :: MonadIO m => Config -> m (Maybe HerculesCipher)
getCipher Config{..} = liftIO $ do
  sayErr ("Trying to open key at: " <> pack configSecretKeyFile)
  key <- readFileMaybe configSecretKeyFile >>= \case
    Nothing -> do
      sayErr ("Unable to open secret key file: " <> pack configSecretKeyFile)
      bytes <- generateNewKey
      sayErr ("Store generated key in file: " <> pack configSecretKeyFile)
      BS.writeFile configSecretKeyFile bytes
      pure bytes
    Just key -> pure key

  case cipherInit key of
    CryptoFailed e -> do
      sayErr ("Unable to create cipher" <> pack (show e))
      pure Nothing
    CryptoPassed cipher -> pure (Just cipher)

-- | Generate random data to build an encryption key.
-- Use system Pseudo-Random-Number-Generator.
generateNewKey :: IO BS.ByteString
generateNewKey = do
  let herculeCipherBlockSize = blockSize (undefined :: HerculesCipher)
  let herculeCipherKeySize = case cipherKeySize (undefined :: HerculesCipher) of
        KeySizeFixed value -> value
        KeySizeEnum values -> maximum values
        KeySizeRange _ maxValue -> maxValue
  sayErr ("Cipher name: " <> pack (show (cipherName (undefined :: HerculesCipher))))
  sayErr ("Cipher block size: " <> pack (show herculeCipherBlockSize))
  sayErr ("Cipher key size: " <> pack (show herculeCipherKeySize))
  bytes <- getEntropy herculeCipherKeySize
  pure bytes

-- | Get the hostname and port for this server separated by a colon
--
-- >>> getHostAndPort
-- "localhost:8080"
getHostAndPort :: App Text
getHostAndPort = do
  hostname <- asks envHostname
  port <- asks envPort
  pure $ hostname <> ":" <> (pack . show $ port)

newEnv :: MonadIO m => Config -> [OAuth2Authenticator App] -> m (Maybe Env)
newEnv c@Config{..} authenticators =
  getHerculesConnection c >>= \case
    Nothing -> pure Nothing
    Just herculesConnection -> liftIO $ do
      hydraConnection <- createPool
        (connectPostgreSQL (encodeUtf8 configHydraConnectionString))
        close
        4 10 4
      httpManager <- newManager tlsManagerSettings
      key <- liftIO generateKey
      let jwtSettings = defaultJWTSettings key
      getCipher c >>= \case
        Nothing -> pure Nothing
        Just cipher ->
          pure . Just $ Env
            herculesConnection
            hydraConnection
            httpManager
            authenticators
            jwtSettings
            cipher
            configPort
            configHostname

-- | Load a yaml configuration and run an 'App' value, useful for testing in
-- the REPL.
runAppWithConfig :: FilePath -> App a -> IO a
runAppWithConfig yaml m =
  decodeFileEither yaml >>= \case
    Left err -> error (prettyPrintParseException err)
    Right config ->
      newEnv config [] >>= \case
        Nothing -> error "Can't create env"
        Just env ->
          runExceptT (runApp env m) >>= \case
            Left err -> error (show err)
            Right x -> pure x
