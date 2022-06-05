module Spectrum.Executor.EventSource.Stream
  ( EventSource(..)
  , mkEventSource
  ) where

import RIO ( (&), MonadReader, (<&>), fromMaybe, ($>) )

import Data.ByteString.Short (toShort)

import Streamly.Prelude as S

import System.Logging.Hlog
  ( MakeLogging(..), Logging(..) )

import Ouroboros.Consensus.Shelley.Ledger
  ( ShelleyBlock(ShelleyBlock), ShelleyHash (unShelleyHash) )
import Ouroboros.Consensus.HardFork.Combinator
  ( OneEraHash(OneEraHash) )
import Ouroboros.Consensus.Cardano.Block
  ( HardForkBlock(BlockAlonzo) )

import Cardano.Ledger.Alonzo.TxSeq
  ( TxSeq(txSeqTxns) )
import qualified Cardano.Ledger.Block as Ledger
import qualified Cardano.Ledger.Shelley.API as TPraos
import qualified Cardano.Crypto.Hash as CC

import Spectrum.LedgerSync.Protocol.Client
  ( Block )
import Spectrum.Executor.EventSource.Data.Tx
  ( fromAlonzoLedgerTx )
import Spectrum.LedgerSync
  ( LedgerSync(..) )
import Spectrum.Context
  ( HasType, askContext )
import Spectrum.Executor.Config
  ( EventSourceConfig (EventSourceConfig, startAt) )
import Spectrum.Executor.Types
  ( ConcretePoint (ConcretePoint), toPoint, fromPoint, ConcretePoint (slot), ConcreteHash (ConcreteHash) )
import Spectrum.Executor.EventSource.Persistence.LedgerHistory
  ( LedgerHistory (..), mkRuntimeLedgerHistory, mkLedgerHistory )
import Spectrum.Executor.EventSource.Data.TxEvent
  ( TxEvent(AppliedTx, UnappliedTx) )
import Spectrum.Executor.EventSource.Data.TxContext
import Spectrum.LedgerSync.Data.LedgerUpdate
  ( LedgerUpdate(RollForward, RollBackward) )
import Ouroboros.Consensus.Block (Point)
import Spectrum.Executor.EventSource.Persistence.Data.BlockLinks
import qualified Data.Set as Set
import Control.Monad.Trans.Control (MonadBaseControl)
import Control.Monad.IO.Class (MonadIO)
import Control.Monad.Catch (MonadThrow)
import Control.Monad (join)
import Spectrum.Executor.EventSource.Persistence.Config (LedgerStoreConfig)
import Control.Monad.Trans.Resource (MonadResource)

newtype EventSource s m = EventSource
  { upstream :: s m (TxEvent 'LedgerTx)
  }

mkEventSource
  :: forall m s env.
    ( IsStream s
    , Monad (s m)
    , MonadAsync m
    , MonadResource m
    , MonadReader env m
    , HasType (MakeLogging m m) env
    , HasType EventSourceConfig env
    , HasType LedgerStoreConfig env
    )
  => LedgerSync m
  -> m (EventSource s m)
mkEventSource lsync = do
  mklog@MakeLogging{..}      <- askContext
  EventSourceConfig{startAt} <- askContext
  lhcong                     <- askContext

  logging     <- forComponent "EventSource"
  persistence <- mkLedgerHistory mklog lhcong

  seekToBeginning logging persistence lsync startAt
  pure $ EventSource $ upstream' logging persistence lsync

upstream'
  :: forall s m. (IsStream s, Monad (s m), MonadAsync m)
  => Logging m
  -> LedgerHistory m
  -> LedgerSync m
  -> s m (TxEvent 'LedgerTx)
upstream' logging@Logging{..} persistence LedgerSync{..}
  = S.repeatM pull >>= processUpdate logging persistence
  & S.trace (infoM . show)

processUpdate
  :: forall s m.
    ( IsStream s
    , Monad (s m)
    , MonadIO m
    , MonadBaseControl IO m
    , MonadThrow m
    )
  => Logging m
  -> LedgerHistory m
  -> LedgerUpdate Block
  -> s m (TxEvent 'LedgerTx)
processUpdate
  _
  LedgerHistory{..}
  (RollForward (BlockAlonzo (ShelleyBlock (Ledger.Block (TPraos.BHeader hBody _) txs) hHash))) =
    let
      txs'  = txSeqTxns txs
      point = ConcretePoint (TPraos.bheaderSlotNo hBody) (ConcreteHash ch)
        where ch = OneEraHash . toShort . CC.hashToBytes . TPraos.unHashHeader . unShelleyHash $ hHash
    in S.before (setTip point)
      $ S.fromFoldable txs' & S.map (AppliedTx . fromAlonzoLedgerTx hHash)
processUpdate logging lh (RollBackward point) = streamUnappliedTxs logging lh point
processUpdate Logging{..} _ upd = S.before (errorM $ "Cannot process update " <> show upd) mempty

streamUnappliedTxs
  :: forall s m.
    ( IsStream s
    , Monad (s m)
    , MonadIO m
    , MonadBaseControl IO m
    , MonadThrow m
    )
  => Logging m
  -> LedgerHistory m
  -> Point Block
  -> s m (TxEvent 'LedgerTx)
streamUnappliedTxs Logging{..} LedgerHistory{..} point = join $ S.fromEffect $ do
  knownPoint <- pointExists $ fromPoint point
  let
    rollbackOne :: ConcretePoint -> s m (TxEvent 'LedgerTx)
    rollbackOne pt = do
      block <- S.fromEffect $ getBlock pt
      case block of
        Just BlockLinks{..} -> do
          S.fromEffect $ dropBlock pt >> setTip prevPoint
          let emitTxs = S.fromFoldable (Set.toList txIds <&> UnappliedTx)
          if toPoint prevPoint == point
            then emitTxs
            else emitTxs <> rollbackOne prevPoint
        Nothing -> mempty
  tipM <- getTip
  case tipM of
    Just tip ->
      if knownPoint
        then infoM ("Rolling back to point " <> show point) $> rollbackOne tip
        else errorM ("An attempt to roll back to an unknown point " <> show point) $> mempty
    Nothing  -> pure mempty

seekToBeginning
  :: Monad m
  => Logging m
  -> LedgerHistory m
  -> LedgerSync m
  -> ConcretePoint
  -> m ()
seekToBeginning Logging{..} LedgerHistory{..} LedgerSync{..} pointLowConf = do
  lastCheckpoint <- getTip
  let
    confSlot = slot pointLowConf
    pointLow = fromMaybe pointLowConf
      $ lastCheckpoint <&> (\p -> if confSlot > slot p then pointLowConf else p)
  infoM $ "Seeking to point " <> show pointLow
  seekTo $ toPoint pointLow
