{-# LANGUAGE CPP                   #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeFamilies          #-}

module Servant.API.WebSocketConduit where

import Control.Concurrent                         (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.Async                   (race_)
import Control.Monad                              (forever, void, (>=>))
import Control.Monad.Catch                        (handle)
import Control.Monad.IO.Class                     (liftIO)
import Control.Monad.Reader.Class                 (asks)
import Control.Monad.Trans.Resource               (ResourceT, runResourceT)
import Data.Aeson                                 (FromJSON, ToJSON, decode, encode)
import Data.Binary.Builder                        (toLazyByteString)
import Data.ByteString.Lazy                       (fromStrict)
import Data.Conduit                               (Conduit, runConduitRes, yieldM, (.|))
import Data.Monoid                                ((<>))
import Data.Proxy                                 (Proxy (..))
import Data.String                                (fromString)
import Data.Text                                  (Text)
import Network.Wai.Handler.WebSockets             (websocketsOr)
import Network.WebSockets                         (ConnectionException, acceptRequest, defaultConnectionOptions,
                                                   forkPingThread, receiveData, receiveDataMessage, runClient,
                                                   sendClose, sendTextData)
import Servant.Client                             (HasClient(..), ClientM, baseUrl, Response)
import Servant.Client.Core.Internal.BaseUrl       (BaseUrl(..))
import Servant.Client.Core.Internal.Request       (Request, requestPath)
import Servant.Client.Core.Internal.RunClient     (RunClient)
import Servant.Server                             (HasServer (..), ServantErr (..), ServerT)
import Servant.Server.Internal.Router             (leafRouter)
import Servant.Server.Internal.RoutingApplication (RouteResult (..), runDelayed)

import qualified Data.Conduit.List as CL

-- | Endpoint for defining a route to provide a websocket. In contrast
-- to the 'WebSocket' endpoint, 'WebSocketConduit' provides a
-- higher-level interface. The handler function must be of type
-- @Conduit i m o@ with @i@ and @o@ being instances of 'FromJSON' and
-- 'ToJSON' respectively. 'await' reads from the web socket while
-- 'yield' writes to it.
--
-- Example:
--
-- >
-- > import Data.Aeson (Value)
-- > import qualified Data.Conduit.List as CL
-- >
-- > type WebSocketApi = "echo" :> WebSocketConduit Value Value
-- >
-- > server :: Server WebSocketApi
-- > server = echo
-- >  where
-- >   echo :: Monad m => Conduit Value m Value
-- >   echo = CL.map id
-- >
--
-- Note that the input format on the web socket is JSON, hence this
-- example only echos valid JSON data.
data WebSocketConduit i o

instance (FromJSON i, ToJSON o) => HasServer (WebSocketConduit i o) ctx where

  type ServerT (WebSocketConduit i o) m = Conduit i (ResourceT IO) o

#if MIN_VERSION_servant_server(0,12,0)
  hoistServerWithContext _ _ _ svr = svr
#endif

  route Proxy _ app = leafRouter $ \env request respond -> runResourceT $
    runDelayed app env request >>= liftIO . go request respond
   where
    go request respond (Route cond) =
      let app = websocketsOr
                  defaultConnectionOptions
                  (runWSApp cond)
                  (backupApp respond)
      in
        app request (respond . Route)

    go _ respond (Fail e) = respond $ Fail e
    go _ respond (FailFatal e) = respond $ FailFatal e

    runWSApp cond = acceptRequest >=> \c -> handle (\(_ :: ConnectionException) -> return ()) $ do
      forkPingThread c 10
      i <- newEmptyMVar
      race_ (forever $ receiveData c >>= putMVar i) $ do
        runConduitRes $ forever (yieldM . liftIO $ takeMVar i)
                     .| CL.mapMaybe (decode . fromStrict)
                     .| cond
                     .| CL.mapM_ (liftIO . sendTextData c . encode)
        sendClose c ("Out of data" :: Text)
        -- After sending the close message, we keep receiving packages
        -- (and drop them) until the connection is actually closed,
        -- which is indicated by an exception.
        forever $ receiveDataMessage c

    backupApp respond _ _ = respond $ Fail ServantErr { errHTTPCode = 426
                                                      , errReasonPhrase = "Upgrade Required"
                                                      , errBody = mempty
                                                      , errHeaders = mempty
                                                      }

class RunClient m => RunWebsocketClient m where
  websocketRequest
    :: (FromJSON i, ToJSON o) => Request -> Conduit i (ResourceT IO) o -> m ()

instance RunWebsocketClient ClientM where
  websocketRequest req cond = do
    burl <- asks baseUrl
    let path = show $ fromString (baseUrlPath burl)
                   <> toLazyByteString (requestPath req)
        host = baseUrlHost burl
        port = baseUrlPort burl
    liftIO . runClient host port path $ \c ->
      handle (\(_ :: ConnectionException) -> return ()) $ do
        forkPingThread c 10
        i <- newEmptyMVar
        race_ (forever $ receiveData c >>= putMVar i) $ do
          runConduitRes $ forever (yieldM . liftIO $ takeMVar i)
            .| CL.mapMaybe (decode . fromStrict)
            .| cond
            .| CL.mapM_ (liftIO . sendTextData c . encode)
        sendClose c ("Out of data" :: Text)
        forever $ receiveDataMessage c

instance (ToJSON i, FromJSON o, RunWebsocketClient m) => HasClient m (WebSocketConduit i o) where
  type Client m (WebSocketConduit i o) = Conduit o (ResourceT IO) i -> m ()
  clientWithRoute pm Proxy = websocketRequest
