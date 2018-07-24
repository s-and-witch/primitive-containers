{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UnboxedTuples #-}

module Data.Map.Subset.Lazy.Lifted
  ( I.Map
  , I.empty
  , singleton
  , antisingleton
  , lookup
  , toList
  , fromList
  ) where

import Prelude hiding (lookup)

import Data.Map.Subset.Lazy.Internal (Map)
import Data.Set.Lifted.Internal (Set(..))
import Data.Bifunctor (first)
import Data.Semigroup (Semigroup)

import qualified Data.Map.Subset.Lazy.Internal as I

-- | A subset map with a single set as its key.
singleton :: 
     Set k
  -> v
  -> Map k v
singleton (Set s) v = I.singleton s v

-- | A subset map with a single negative set as its key. That is,
-- a lookup into this map will only succeed if the needle set and the
-- negative set do not overlap.
antisingleton ::
     Set k -- ^ negative set
  -> v -- ^ value
  -> Map k v
antisingleton (Set s) v = I.singleton s v

lookup :: Ord k => Set k -> Map k v -> Maybe v
lookup (Set s) m = I.lookup s m

toList :: Map k v -> [(Set k,v)]
toList = map (first Set) . I.toList

fromList :: Ord k => [(Set k,v)] -> Map k v
fromList = I.fromList . map (first getSet)

