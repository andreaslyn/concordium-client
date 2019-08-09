{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE NamedFieldPuns #-}

module Api where

import Network.Wai              (Application)
import Control.Monad.Managed    (liftIO)
import Data.Text                (Text)
import Servant
import Servant.API.Generic
import Servant.Server.Generic


import           Concordium.Client.Runner
import           Concordium.Client.Runner.Helper
import           Concordium.Client.Types.Transaction
import           Concordium.Client.Commands          as COM
import qualified Acorn.Parser.Runner                 as PR
import qualified Concordium.Scheduler.Types          as Types


data Routes r = Routes
    { sendTransaction :: r :-
        "v1" :> "sendTransaction" :> ReqBody '[JSON] TransactionJSON
                                  :> Post '[JSON] Text
    }
  deriving (Generic)


api :: Proxy (ToServantApi Routes)
api = genericApi (Proxy :: Proxy Routes)


servantApp :: COM.Backend -> Application
servantApp backend = genericServe routesAsServer
 where
  routesAsServer = Routes {..} :: Routes AsServer

  sendTransaction :: TransactionJSON -> Handler Text
  sendTransaction transaction = do
    liftIO $ do
      mdata <- loadContextData

      let nid = 1234 -- @TODO what is the network ID actually for...? What should it be in wallet context?

      t <- do
        let hookIt = False
        PR.evalContext mdata $ runInClient backend $ processTransaction_ transaction nid hookIt

      putStrLn $ "Transaction sent to the baker: " ++ show (Types.trHash t)

    -- @TODO What response should we send?
    pure "Submitted"
