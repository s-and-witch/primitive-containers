{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleInstances #-}

-- The simplifiable class constraints warning is suppress because
-- these redundant Always constraints are needed to make backpack 
-- see that type signatures match up.
{-# OPTIONS_GHC -fno-warn-simplifiable-class-constraints #-}

module ValueLifted where

import Control.Monad.ST (ST)
import Data.Primitive.Types
import Data.Primitive.Array
import qualified Data.Foldable as F

class Always a where

instance Always a

type MArr = MutableArray
type Arr = Array
type Ctx = Always

errorThunk :: a
errorThunk = error "primitive-containers: ValueLifted: uninitialized element"
{-# NOINLINE errorThunk #-}

new :: Always a => Int -> ST s (MutableArray s a)
new n = newArray n errorThunk

index :: Always a => Array a -> Int -> a
index = indexArray

read :: Always a => MutableArray s a -> Int -> ST s a
read = readArray

write :: Always a => MutableArray s a -> Int -> a -> ST s ()
write = writeArray

resize :: Always a => MutableArray s a -> Int -> ST s (MutableArray s a)
resize src sz = do
  dst <- newArray sz errorThunk
  copyMutableArray dst 0 src 0 sz
  return dst

copy :: Always a => MutableArray s a -> Int -> Array a -> Int -> Int -> ST s ()
copy = copyArray

unsafeFreeze :: MutableArray s a -> ST s (Array a)
unsafeFreeze = unsafeFreezeArray

size :: Always a => Array a -> Int
size = sizeofArray

foldr :: Always a => (a -> b -> b) -> b -> Array a -> b
foldr = F.foldr

