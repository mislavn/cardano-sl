{-# LANGUAGE GADTs          #-}
{-# LANGUAGE NamedFieldPuns #-}

-- | Tx sending functionality in Auxx.

module Command.Tx
       ( SendToAllGenesisParams (..)
       , sendToAllGenesis
       , send
       , sendTxsFromFile
       ) where

import           Universum

import           Control.Concurrent.STM.TQueue (newTQueue, tryReadTQueue, writeTQueue)
import           Control.Exception.Safe (Exception (..), try)
import           Control.Monad (forM, zipWithM_)
import           Control.Monad.Except (runExceptT)
import           Data.Aeson (eitherDecodeStrict)
import qualified Data.ByteString as BS
import           Data.Default (def)
import qualified Data.HashMap.Strict as HM
import           Data.List ((!!))
import qualified Data.List.NonEmpty as NE
import qualified Data.Map as M
import qualified Data.Text as T
import qualified Data.Text.IO as T
import           Data.Time.Units (toMicroseconds)
import           Formatting (build, int, sformat, shown, stext, (%))
import           Mockable (Mockable, SharedAtomic, SharedAtomicT, concurrently, currentTime, delay,
                           forConcurrently, modifySharedAtomic, newSharedAtomic)
import           Serokell.Util (ms, sec)
import           System.Environment (lookupEnv)
import           System.IO (BufferMode (LineBuffering), hClose, hSetBuffering)
import           System.Wlog (logError, logInfo)

import           Pos.Client.KeyStorage (getSecretKeysPlain)
import           Pos.Client.Txp.Balances (getOwnUtxoForPk)
import           Pos.Client.Txp.Network (prepareMTx, submitTxRaw)
import           Pos.Client.Txp.Util (createTx)
import           Pos.Core (BlockVersionData (bvdSlotDuration), IsBootstrapEraAddr (..),
                           Timestamp (..), deriveFirstHDAddress, getCoin, makePubKeyAddress, mkCoin)
import           Pos.Core.Configuration (genesisBlockVersionData, genesisSecretKeys)
import           Pos.Core.Txp (TxAux (..), TxIn (TxInUtxo), TxOut (..), TxOutAux (..), txaF)
import           Pos.Crypto (EncryptedSecretKey, emptyPassphrase, encToPublic, fakeSigner, hash,
                             safeToPublic, toPublic, withSafeSigners)
import           Pos.Diffusion.Types (Diffusion (..))
import           Pos.Txp (topsortTxAuxes)
import           Pos.Util.UserSecret (usWallet, userSecret, wusRootKey)
import           Pos.Util.Util (maybeThrow)

import           Mode (MonadAuxxMode, makePubKeyAddressAuxx)

----------------------------------------------------------------------------
-- Send to all genesis
----------------------------------------------------------------------------

-- | Parameters for 'SendToAllGenesis' command.
data SendToAllGenesisParams = SendToAllGenesisParams
    { stagpDuration    :: !Int
    , stagpConc        :: !Int
    , stagpDelay       :: !Int
    , stagpTpsSentFile :: !FilePath
    } deriving (Show)

-- | Count submitted and failed transactions.
--
-- This is used in the benchmarks using send-to-all-genesis
data TxCount = TxCount
    { _txcSubmitted :: !Int
    , _txcFailed    :: !Int
      -- How many threads are still sending transactions.
    , _txcThreads   :: !Int }

addTxSubmit :: Mockable SharedAtomic m => SharedAtomicT m TxCount -> m ()
addTxSubmit =
    flip modifySharedAtomic
        (\(TxCount submitted failed sending) ->
             pure (TxCount (submitted + 1) failed sending, ()))

{-
addTxFailed :: Mockable SharedAtomic m => SharedAtomicT m TxCount -> m ()
addTxFailed =
    flip modifySharedAtomic
        (\(TxCount submitted failed sending) ->
             pure (TxCount submitted (failed + 1) sending, ()))
-}

sendToAllGenesis
    :: forall m. MonadAuxxMode m
    => Diffusion m
    -> SendToAllGenesisParams
    -> m ()
sendToAllGenesis diffusion (SendToAllGenesisParams duration conc delay_ tpsSentFile) = do
    let genesisSlotDuration = fromIntegral (toMicroseconds $ bvdSlotDuration genesisBlockVersionData) `div` 1000000 :: Int
        keysToSend  = fromMaybe (error "Genesis secret keys are unknown") genesisSecretKeys
    tpsMVar <- newSharedAtomic $ TxCount 0 0 conc
    startTime <- show . toInteger . getTimestamp . Timestamp <$> currentTime
    bracket (openFile tpsSentFile WriteMode) (liftIO . hClose) $ \h -> do
        liftIO $ hSetBuffering h LineBuffering
        liftIO . T.hPutStrLn h $ T.intercalate "," [ "slotDuration=" <> show genesisSlotDuration
                                                   , "conc=" <> show conc
                                                   , "startTime=" <> startTime
                                                   , "delay=" <> show delay_ ]
        liftIO $ T.hPutStrLn h "time,txCount,txType"
        txQueue <- atomically $ newTQueue
        txQueue' <- atomically $ newTQueue
        -- prepare a queue with all transactions
        logInfo $ sformat ("Found "%shown%" keys in the genesis block.") (length keysToSend)
        startAtTxt <- liftIO $ lookupEnv "AUXX_START_AT"
        let startAt = fromMaybe 0 . readMaybe . fromMaybe "" $ startAtTxt :: Int
        -- construct a transaction, and add it to the queue
        let addTx fromKey outAddr = do
                -- construct transaction output
                selfAddr <- makePubKeyAddressAuxx $ toPublic fromKey
                let val1 = 1
                    txOut1 = TxOut {
                        txOutAddress = selfAddr,
                        txOutValue = mkCoin val1
                        }
                    txOuts = TxOutAux txOut1 :| []
                utxo <- getOwnUtxoForPk $ safeToPublic (fakeSigner fromKey)
                etx <- createTx mempty utxo (fakeSigner fromKey) txOuts (toPublic fromKey)
                case etx of
                    Left err -> logError (sformat ("Error: "%build%" while trying to contruct tx") err)
                    Right (tx, txOut1new) -> do
                        -- logInfo $ "Utxo: " <> show utxo
                        -- logInfo $ "txOuts: " <> show txOuts
                        -- logInfo $ "selfAddr: " <> show selfAddr
                        -- logInfo $ "outAddr: " <> show outAddr
                        -- logInfo $ "txOut1new: " <> show txOut1new
                        -- see if txOut1new can be used
                        let txOut1' = TxOut {
                                txOutAddress = selfAddr,  -- better (.) ??
                                txOutValue = mkCoin $ (getCoin $ txOutValue $ NE.head txOut1new) - val1 -- 636428571 -- txout1new - 1
                                }
                        atomically $ writeTQueue txQueue tx
                        atomically $ writeTQueue txQueue' (tx, txOut1', fromKey, outAddr)
        let nTrans = conc * duration -- number of transactions we'll send
            allTrans@(t:ts) = take nTrans (drop startAt keysToSend)
            -- (firstBatch, secondBatch) = splitAt ((2 * nTrans) `div` 3) allTrans
            -- every <slotDuration> seconds, write the number of sent and failed transactions to a CSV file.
            writeTPS :: m ()
            writeTPS = do
                delay (sec genesisSlotDuration)
                curTime <- show . toInteger . getTimestamp . Timestamp <$> currentTime
                finished <- modifySharedAtomic tpsMVar $ \(TxCount submitted failed sending) -> do
                    -- CSV is formatted like this:
                    -- time,txCount,txType
                    liftIO $ T.hPutStrLn h $ T.intercalate "," [curTime, show $ submitted, "submitted"]
                    liftIO $ T.hPutStrLn h $ T.intercalate "," [curTime, show $ failed, "failed"]
                    return (TxCount 0 0 sending, sending <= 0)
                if finished
                    then logInfo "Finished writing TPS samples."
                    else writeTPS
            -- Repeatedly take transactions from the queue and send them.
            -- Do this n times.
            sendTxs :: Int -> m ()
            sendTxs n
                | n <= 0 = do
                      logInfo "All done sending transactions on this thread."
                      modifySharedAtomic tpsMVar $ \(TxCount submitted failed sending) ->
                          return (TxCount submitted failed (sending - 1), ())
                | otherwise = (atomically $ tryReadTQueue txQueue) >>= \case
                      Just tx -> do
                          res <- submitTxRaw diffusion tx
                          addTxSubmit tpsMVar
                          logInfo $ if res
                                    then sformat ("Submitted transaction: "%txaF) tx
                                    else sformat ("Applied transaction "%txaF%", however no neighbour applied it") tx
                          delay $ ms delay_
                          logInfo "Continuing to send transactions."
                          sendTxs (n - 1)
                      Nothing -> do
                          logInfo "No more transactions in the queue."
                          sendTxs 0
            -- prepare Txs whose input does not belong in genesis block
            prepareTxs :: Int -> m ()
            prepareTxs n --remainder
                | n <= 0 = return ()
                | otherwise = (atomically $ tryReadTQueue txQueue') >>= \case
                    Just (tx, txOut1', sender, receiver) -> do
                        let txInp = TxInUtxo (hash (taTx tx)) 0
                            utxo' = M.fromList [(txInp, TxOutAux txOut1')]
                            txOut2 = TxOut {
                                txOutAddress = receiver,
                                txOutValue = mkCoin 1
                                }
                            txOuts2 = TxOutAux txOut2 :| []
                        -- logInfo $ "Utxo': " <> show utxo'
                        -- logInfo $ "txOuts2: " <> show txOuts2
                        -- selfAddr <- makePubKeyAddressAuxx $ toPublic sender
                        -- logInfo $ "selfAddr: " <> show selfAddr
                        -- logInfo $ "receiver: " <> show receiver
                        etx' <- createTx mempty utxo' (fakeSigner sender) txOuts2 (toPublic sender)
                        case etx' of
                            Left err -> logError (sformat ("Error: "%build%" while trying to contruct tx") err)
                            Right (tx', _) -> atomically $ writeTQueue txQueue tx'
                        -- sendTxs 1 addition to prepare another if there are not adequate
                        -- with the same sender and receiver just writing in txQueue'
                        -- logInfo "Trying send finished."
                        prepareTxs $ n - 1
                    Nothing -> logInfo "No more transactions in the queue2."

            sendTxsConcurrently n = void $ forConcurrently [1..conc] (const (sendTxs n))
        -- pre construct the first batch of transactions. Otherwise,
        -- we'll be CPU bound and will not achieve high transaction
        -- rates. If we pre construct all the transactions, the
        -- startup time will be quite long.
        -- outAddresses <- forM (ts++[t]) $ \k -> makePubKeyAddressAuxx (toPublic (fromMaybe (error "sendToAllGenesis: no keys") $ Just k))
        logInfo $ "length allTrans:" <> (show (length allTrans))
        outAddresses <- forM (ts++[t]) $ makePubKeyAddressAuxx . toPublic
        -- forM_ allTrans addTx -- forM_  firstBatch addTx
        zipWithM_ addTx allTrans outAddresses
        -- Send transactions while concurrently writing the TPS numbers every
        -- slot duration. The 'writeTPS' action takes care to *always* write
        -- after every slot duration, even if it is killed, so as to
        -- guarantee that we don't miss any numbers.
        --
        -- While we're sending, we're constructing the second batch of
        -- transactions.
        -- prepareTxs duration
        prepareTxs nTrans
        void $
            -- concurrently (forM_ secondBatch addTx) $
            -- concurrently (prepareTxs duration) $
            concurrently writeTPS (sendTxsConcurrently (2*duration))
        -- sendTxs nTrans

----------------------------------------------------------------------------
-- Casual sending
----------------------------------------------------------------------------

newtype AuxxException = AuxxException Text
  deriving (Show)

instance Exception AuxxException

send
    :: forall m. MonadAuxxMode m
    => Diffusion m
    -> Int
    -> NonEmpty TxOut
    -> m ()
send diffusion idx outputs = do
    skey <- takeSecret
    let curPk = encToPublic skey
    let plainAddresses = map (flip makePubKeyAddress curPk . IsBootstrapEraAddr) [False, True]
    let (hdAddresses, hdSecrets) = unzip $ map
            (\ibea -> fromMaybe (error "send: pass mismatch") $
                    deriveFirstHDAddress (IsBootstrapEraAddr ibea) emptyPassphrase skey) [False, True]
    let allAddresses = hdAddresses ++ plainAddresses
    let allSecrets = hdSecrets ++ [skey, skey]
    etx <- withSafeSigners allSecrets (pure emptyPassphrase) $ \signers -> runExceptT @AuxxException $ do
        let addrSig = HM.fromList $ zip allAddresses signers
        let getSigner addr = HM.lookup addr addrSig
        -- BE CAREFUL: We create remain address using our pk, wallet doesn't show such addresses
        (txAux,_) <- lift $ prepareMTx getSigner mempty def (NE.fromList allAddresses) (map TxOutAux outputs) curPk
        txAux <$ (ExceptT $ try $ submitTxRaw diffusion txAux)
    case etx of
        Left err -> logError $ sformat ("Error: "%stext) (toText $ displayException err)
        Right tx -> logInfo $ sformat ("Submitted transaction: "%txaF) tx
  where
    takeSecret :: m EncryptedSecretKey
    takeSecret
        | idx == -1 = do
            _userSecret <- view userSecret >>= atomically . readTVar
            pure $ maybe (error "Unknown wallet address") (^. wusRootKey) (_userSecret ^. usWallet)
        | otherwise = do
            logInfo $ show idx
            (!! idx) <$> getSecretKeysPlain

----------------------------------------------------------------------------
-- Send from file
----------------------------------------------------------------------------

-- | Read transactions from the given file (ideally generated by
-- 'rollbackAndDump') and submit them to the network.
sendTxsFromFile
    :: forall m. MonadAuxxMode m
    => Diffusion m
    -> FilePath
    -> m ()
sendTxsFromFile diffusion txsFile = do
    liftIO (BS.readFile txsFile) <&> eitherDecodeStrict >>= \case
        Left err -> throwM (AuxxException $ toText err)
        Right txs -> sendTxs txs
  where
    sendTxs :: [TxAux] -> m ()
    sendTxs txAuxes = do
        logInfo $
            sformat
                ("Going to send "%int%" transactions one-by-one")
                (length txAuxes)
        sortedTxAuxes <-
            maybeThrow
                (AuxxException "txs form a cycle")
                (topsortTxAuxes txAuxes)
        let submitOne = submitTxRaw diffusion
        mapM_ submitOne sortedTxAuxes
