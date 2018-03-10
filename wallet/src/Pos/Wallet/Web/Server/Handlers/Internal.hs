{-# LANGUAGE Rank2Types   #-}
{-# LANGUAGE TypeFamilies #-}

-- | Wallet endpoints list

module Pos.Wallet.Web.Server.Handlers.Internal
       ( testHandlers
       , walletsHandlers
       , accountsHandlers
       , addressesHandlers
       , profileHandlers
       , txsHandlers
       , updateHandlers
       , redemptionsHandlers
       , reportingHandlers
       , settingsHandlers
       , backupHandlers
       , infoHandlers
       , systemHandlers

       , toServant'
       ) where

import           Universum

import           Servant.Generic          (AsServerT, GenericProduct, ToServant, toServant)
import           Servant.Server           (ServerT)

import           Pos.Core.Txp             (TxAux)
import           Pos.Update.Configuration (curSoftwareVersion)

import           Pos.Wallet.WalletMode    (blockchainSlotDuration)
import           Pos.Wallet.Web.Account   (GenSeed (RandomSeed))
import qualified Pos.Wallet.Web.Api       as A
import qualified Pos.Wallet.Web.Methods   as M
import           Pos.Wallet.Web.Mode      (MonadFullWalletWebMode)

-- branches of the API

testHandlers :: MonadFullWalletWebMode ctx m => ServerT A.WTestApi m
testHandlers = toServant' A.WTestApiRecord
    { _testReset = M.testResetAll
    , _testState = M.dumpState
    }

walletsHandlers :: MonadFullWalletWebMode ctx m => ServerT A.WWalletsApi m
walletsHandlers = toServant' A.WWalletsApiRecord
    { _getWallet              = M.getWallet
    , _getWallets             = M.getWallets
    , _newWallet              = M.newWallet
    , _updateWallet           = M.updateWallet
    , _restoreWallet          = M.restoreWallet
    , _deleteWallet           = M.deleteWallet
    , _importWallet           = M.importWallet
    , _changeWalletPassphrase = M.changeWalletPassphrase
    }

accountsHandlers :: MonadFullWalletWebMode ctx m => ServerT A.WAccountsApi m
accountsHandlers = toServant' A.WAccountsApiRecord
    { _getAccount    = M.getAccount
    , _getAccounts   = M.getAccounts
    , _updateAccount = M.updateAccount
    , _newAccount    = M.newAccount RandomSeed
    , _deleteAccount = M.deleteAccount
    }

addressesHandlers :: MonadFullWalletWebMode ctx m => ServerT A.WAddressesApi m
addressesHandlers = toServant' A.WAddressesApiRecord
    { _newAddress     = M.newAddress RandomSeed
    , _isValidAddress = M.isValidAddress
    }

profileHandlers :: MonadFullWalletWebMode ctx m => ServerT A.WProfileApi m
profileHandlers = toServant' A.WProfileApiRecord
    { _getProfile    = M.getUserProfile
    , _updateProfile = M.updateUserProfile
    }

txsHandlers :: MonadFullWalletWebMode ctx m => (TxAux -> m Bool) -> ServerT A.WTxsApi m
txsHandlers submitTx = toServant' A.WTxsApiRecord
    { _newPayment                = M.newPayment submitTx
    , _newPaymentBatch           = M.newPaymentBatch submitTx
    , _txFee                     = M.getTxFee
    , _resetFailedPtxs           = M.resetAllFailedPtxs
    , _cancelApplyingPtxs        = M.cancelAllApplyingPtxs
    , _cancelSpecificApplyingPtx = M.cancelOneApplyingPtx
    , _getHistory                = M.getHistoryLimited
    , _pendingSummary            = M.gatherPendingTxsSummary
    }

updateHandlers :: MonadFullWalletWebMode ctx m => ServerT A.WUpdateApi m
updateHandlers = toServant' A.WUpdateApiRecord
    { _nextUpdate     = M.nextUpdate
    , _postponeUpdate = M.postponeUpdate
    , _applyUpdate    = M.applyUpdate
    }

redemptionsHandlers :: MonadFullWalletWebMode ctx m => (TxAux -> m Bool) -> ServerT A.WRedemptionsApi m
redemptionsHandlers submitTx = toServant' A.WRedemptionsApiRecord
    { _redeemADA          = M.redeemAda submitTx
    , _redeemADAPaperVend = M.redeemAdaPaperVend submitTx
    }

reportingHandlers :: MonadFullWalletWebMode ctx m => ServerT A.WReportingApi m
reportingHandlers = toServant' A.WReportingApiRecord
    { _reportingInitialized = M.reportingInitialized
    }

settingsHandlers :: MonadFullWalletWebMode ctx m => ServerT A.WSettingsApi m
settingsHandlers = toServant' A.WSettingsApiRecord
    { _getSlotsDuration    = blockchainSlotDuration <&> fromIntegral
    , _getVersion          = pure curSoftwareVersion
    , _getSyncProgress     = M.syncProgress
    , _localTimeDifference = M.localTimeDifference
    }

backupHandlers :: MonadFullWalletWebMode ctx m => ServerT A.WBackupApi m
backupHandlers = toServant' A.WBackupApiRecord
    { _importBackupJSON = M.importWalletJSON
    , _exportBackupJSON = M.exportWalletJSON
    }

infoHandlers :: MonadFullWalletWebMode ctx m => ServerT A.WInfoApi m
infoHandlers = toServant' A.WInfoApiRecord
    { _getClientInfo = M.getClientInfo
    }

systemHandlers :: MonadFullWalletWebMode ctx m => ServerT A.WSystemApi m
systemHandlers = toServant' A.WSystemApiRecord
    { _requestShutdown = M.requestShutdown
    }

----------------------------------------------------------------------------
-- Utilities
----------------------------------------------------------------------------

-- | A type-restricted synonym for 'toServant' that lets us avoid some type
-- annotations
toServant'
    :: (a ~ r (AsServerT m), GenericProduct a)
    => a -> ToServant a
toServant' = toServant
