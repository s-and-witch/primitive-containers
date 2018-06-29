{-# language FlexibleContexts #-}
{-# language GeneralizedNewtypeDeriving #-}
{-# language PolyKinds #-}
{-# language TypeFamilies #-}

module Data.Dependent.Map.Unboxed.Lifted
  ( Map
  , singleton
  , lookup
  , toList
  , fromList
  ) where

import Prelude hiding (lookup)

import Data.Primitive (Array,PrimArray,Prim)
import Data.Semigroup (Semigroup)
import Data.Dependent.Map.Class (Universally,ApplyUniversally)
import Data.Exists (OrdForallPoly,DependentPair,ShowForall,ShowForeach,ToSing)
import Data.Exists (EqForallPoly,EqForeach,OrdForeach)
import GHC.Exts (IsList)

import qualified Data.Dependent.Map.Internal as I
import qualified GHC.Exts

newtype Map k v = Map (I.Map PrimArray Array k v)

singleton :: Universally k Prim => k a -> v a -> Map k v
singleton f v = Map (I.singleton f v)

lookup :: (Universally k Prim, ApplyUniversally k Prim, OrdForallPoly k) => k a -> Map k v -> Maybe (v a)
lookup k (Map x) = I.lookup k x

fromList :: (Universally k Prim, ApplyUniversally k Prim, OrdForallPoly k) => [DependentPair k v] -> Map k v
fromList xs = Map (I.fromList xs)

fromListN :: (Universally k Prim, ApplyUniversally k Prim, OrdForallPoly k) => Int -> [DependentPair k v] -> Map k v
fromListN n xs = Map (I.fromListN n xs)

toList :: Universally k Prim => Map k v -> [DependentPair k v]
toList (Map x) = I.toList x

instance (Universally k Prim, ApplyUniversally k Prim, OrdForallPoly k) => IsList (Map k v) where
  type Item (Map k v) = DependentPair k v
  fromListN = fromListN
  fromList = fromList
  toList = toList
  
instance (Universally k Prim, ApplyUniversally k Prim, ShowForall k, ToSing k, ShowForeach v) => Show (Map k v) where
  showsPrec p (Map s) = I.showsPrec p s

instance (Universally k Prim, ApplyUniversally k Prim, EqForallPoly k, ToSing k, EqForeach v) => Eq (Map k v) where
  Map x == Map y = I.equals x y

instance (Universally k Prim, ApplyUniversally k Prim, OrdForallPoly k, ToSing k, OrdForeach v) => Ord (Map k v) where
  compare (Map x) (Map y) = I.compare x y



