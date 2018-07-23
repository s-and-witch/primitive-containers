{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UnboxedTuples #-}

module Data.Map.Subset.Lazy.Unlifted
  ( I.Map
  , I.empty
  , singleton
  , lookup
  , toList
  , fromList
  ) where

import Prelude hiding (lookup)

import Data.Map.Subset.Lazy.Internal (Map)
import Data.Set.Unlifted.Internal (Set(..))
import Data.Bifunctor (first)
import Data.Semigroup (Semigroup)
import Data.Primitive (PrimUnlifted)

import qualified Data.Map.Subset.Lazy.Internal as I

singleton :: (PrimUnlifted k, Monoid v)
  => Set k
  -> v
  -> Map k v
singleton (Set s) v = I.singleton s v

lookup :: (Ord k, PrimUnlifted k) => Set k -> Map k v -> Maybe v
lookup (Set s) m = I.lookup s m

toList :: PrimUnlifted k => Map k v -> [(Set k,v)]
toList = map (first Set) . I.toList

fromList :: (Ord k, PrimUnlifted k, Semigroup v) => [(Set k,v)] -> Map k v
fromList = I.fromList . map (first getSet)

