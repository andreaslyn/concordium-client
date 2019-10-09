{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE LambdaCase #-}
{-# OPTIONS_GHC -Wall #-}
module Main where

import           Concordium.Client.Commands
import           Concordium.Client.Runner
import           Concordium.GlobalState.Transactions
import           Concordium.Types
import           Concordium.Types.Execution
import           Control.Concurrent
import           Control.Monad.Reader
import           Options.Applicative
import Concordium.ID.Account as AH

import Data.Time.Clock
import qualified Data.Aeson as AE
import qualified Data.Aeson.Types as AE
import qualified Data.ByteString.Lazy as BSL

import qualified Concordium.Crypto.SignatureScheme as Sig

data TxOptions = TxOptions {
  -- |What is the starting nonce.
  startNonce :: Nonce,
  -- |How many transactions to send per batch.
  perBatch   :: Int,
  -- |In seconds.
  delay      :: Int,
  -- |File with JSON encoded keys for the source account.
  keysFile :: FilePath
  }

txOptions :: Parser TxOptions
txOptions = do
  let startNonce :: Parser Word = option auto (value 1 <>
                                               showDefault <>
                                               long "nonce" <>
                                               metavar "NONCE" <>
                                               help "Nonce to start generation with.")
  let perBatch = option auto (value 10 <>
                              showDefault <>
                              long "batch" <>
                              metavar "NUM" <>
                              help "Size of a batch to send at once.")
  let delay = option auto (value 10 <>
                           showDefault <>
                           long "delay" <>
                           metavar "SECONDS" <>
                           help "Delay between batches.")
  let keys = strOption (long "keyPair" <> short 'k' <> metavar "FILENAME")
  TxOptions . fromIntegral <$> startNonce <*> perBatch <*> delay <*> keys

grpcBackend :: Parser Backend
grpcBackend = GRPC <$> hostParser <*> portParser <*> targetParser

parser :: ParserInfo (Backend, TxOptions)
parser = info (helper <*> ((,) <$> grpcBackend <*> txOptions))
         (fullDesc <> progDesc "Generate transactions for a fixed contract.")

sendTx :: MonadIO m => BareTransaction -> ClientMonad m BareTransaction
sendTx tx = sendTransactionToBaker tx 100 >> return tx

iterateM_ :: Monad m => (a -> m a) -> a -> m b
iterateM_ f a = f a >>= iterateM_ f

go :: Backend -> Int -> Int -> (Nonce -> BareTransaction) -> Nonce -> IO ()
go backend delay perBatch sign startNonce = do
  -- restart connection every 100 transactions
  startTime <- getCurrentTime
  iterateM_ (runInClient backend . loop startTime 100) (0, startNonce)

  where loop startTime left p@(total, nonce) | left <= 0 = return p
                                           | otherwise = do
          let nextNonce = nonce + fromIntegral perBatch
          mapM_ (sendTx . sign) [nonce..nextNonce-1]
          let newTotal = total + perBatch
          liftIO $ do
            currentTime <- getCurrentTime
            let rate = show (fromIntegral (total + perBatch) / (diffUTCTime currentTime startTime))
            putStrLn $ "Total transactions sent to " ++ show (target backend) ++ " = " ++ show newTotal ++ ", rate per second = " ++ show rate
            threadDelay (delay * 10^(6::Int))
          loop startTime (left - perBatch) (newTotal, nextNonce)

main :: IO ()
main = do
  (backend, txoptions) <- execParser parser
  AE.eitherDecode <$> BSL.readFile (keysFile txoptions) >>= \case
    Left err -> putStrLn $ "Could not read the keys because: " ++ err
    Right v ->
      case AE.parseEither parseKeys v of
        Left err' -> putStrLn $ "Could not decode JSON because: " ++ err'
        Right keyPair@Sig.KeyPair{..} -> do
          let selfAddress = AH.accountAddress verifyKey Sig.Ed25519
          print $ "Using sender account = " ++ show selfAddress
          let txBody = encodePayload (Transfer (AddressAccount selfAddress) 1) -- transfer 1 GTU to myself.
          let txHeader nonce = makeTransactionHeader Sig.Ed25519 verifyKey (payloadSize txBody) nonce 1000
          let sign nonce = signTransaction keyPair (txHeader nonce) txBody
          go backend (delay txoptions) (perBatch txoptions) sign (startNonce txoptions)

  where parseKeys = AE.withObject "Account keypair" $ \obj -> do
          verifyKey <- obj AE..: "verifyKey"
          signKey <- obj AE..: "signKey"
          return $ Sig.KeyPair{..}
