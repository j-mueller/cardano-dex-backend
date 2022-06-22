module Spectrum.Executor.Backlog.Service where

import qualified Database.RocksDB as Rocks

import qualified Data.PQueue.Max as PQ
import qualified Data.Sequence as Seq

import Spectrum.Executor.Data.OrderState (OrderState (..), OrderInState (PendingOrder, SuspendedOrder))
import Spectrum.Executor.Types (OrderId, Order, orderId)

import Spectrum.Common.Persistence.Serialization
  ( serialize, deserializeM )
import System.Logging.Hlog (MakeLogging(MakeLogging, forComponent))
import Spectrum.Executor.Backlog.Config (BacklogConfig(..))
import Control.Monad.IO.Class
import Control.Monad.Trans.Resource
import Data.Aeson (FromJSON)
import RIO
import Spectrum.Executor.Backlog.Data.BacklogOrder (mkWeightedOrder)

data Backlog m = Backlog
  { put        :: OrderInState 'Pending -> m ()
  , suspend    :: OrderInState 'Suspended -> m Bool
  , checkLater :: OrderInState 'InProgress -> m Bool
  , tryAcquire :: m (Maybe Order)
  , drop       :: OrderId -> m Bool
  }

mkBacklog
  :: forall f m. (MonadIO f, MonadResource f, MonadIO m, MonadThrow m)
  => MakeLogging f m
  -> BacklogConfig
  -> f (Backlog m)
mkBacklog MakeLogging{..} BacklogConfig{..} = do
  logging     <- forComponent "Pools"
  -- those queues should be shared with Backlog.Proceess (to make live updates). So maybe worth extracting them into separate module. e.g. BacklogStore
  pendingPQ   <- newIORef PQ.empty  -- ordered by weight; new orders
  suspendedPQ <- newIORef PQ.empty  -- ordered by weight; failed orders, waiting for retry (retries are performed with some constant probability, e.g. 5%) 
  toRevisitQ  <- newIORef Seq.empty -- regular queue; successully submitted orders. Left orders should be re-executed in X minutes. Normally successfully confirmed orders are eliminated from this queue.

  (_, db) <- Rocks.openBracket storePath
              Rocks.defaultOptions
                { Rocks.createIfMissing = createIfMissing
                }
  let
    get :: FromJSON a => ByteString -> m (Maybe a)
    get = (=<<) (mapM deserializeM) . Rocks.get db Rocks.defaultReadOptions
    exists :: ByteString -> m Bool
    exists k = Rocks.get db Rocks.defaultReadOptions k <&> isJust
    put = Rocks.put db Rocks.defaultWriteOptions
    -- delete = Rocks.delete db Rocks.defaultWriteOptions
  pure Backlog
    { put = \(PendingOrder ord) -> do
        put (serialize $ orderId ord) (serialize ord)
        modifyIORef pendingPQ . PQ.insert . mkWeightedOrder $ ord
    , suspend = \(SuspendedOrder ord) -> do
        modifyIORef suspendedPQ . PQ.insert . mkWeightedOrder $ ord
        exists . serialize . orderId $ ord
    , checkLater = undefined
    }