{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UnboxedTuples #-}

{-# OPTIONS_GHC -O2 -Wall #-}
module Data.Map.Internal
  ( Map
  , empty
  , singleton
  , null
  , map
  , mapWithKey
  , mapMaybe
  , mapMaybeP
  , mapMaybeWithKey
    -- * Folds
  , foldrWithKey
  , foldlWithKey'
  , foldrWithKey'
  , foldMapWithKey
  , foldMapWithKey'
    -- * Monadic Folds
  , foldlWithKeyM'
  , foldrWithKeyM'
  , foldlMapWithKeyM'
  , foldrMapWithKeyM'
    -- * Traversals
  , traverse
  , traverseWithKey
  , traverseWithKey_
    -- * Functions
  , append
  , appendWith
  , appendWithKey
  , appendRightBiased
  , intersectionWith
  , intersectionsWith
  , adjustMany
  , adjustManyInline
  , lookup
  , showsPrec
  , equals
  , compare
  , toList
  , concat
  , size
  , sizeKeys
  , keys
  , elems
  , restrict
  , rnf
    -- * List Conversion
  , fromListN
  , fromList
  , fromListAppend
  , fromListAppendN
  , fromSet
  , fromSetP
    -- * Array Conversion
  , unsafeFreezeZip
  , unsafeZipPresorted
  ) where

import Prelude hiding (compare,showsPrec,lookup,map,concat,null,traverse)

import Control.Applicative (liftA2)
import Control.DeepSeq (NFData)
import Control.Monad.Primitive (PrimMonad,PrimState)
import Control.Monad.ST (ST,runST)
import Data.List.NonEmpty (NonEmpty)
import Data.Primitive.Contiguous (ContiguousU,Mutable,Element)
import Data.Primitive.Sort (sortUniqueTaggedMutable)
import Data.Set.Internal (Set(..))

import qualified Data.Concatenation as C
import qualified Data.Primitive.Contiguous as I
import qualified Data.Semigroup as SG
import qualified Prelude as P

-- TODO: Do some sneakiness with UnliftedRep
data Map karr varr k v = Map !(karr k) !(varr v)

empty :: (ContiguousU karr, ContiguousU varr) => Map karr varr k v
empty = Map I.empty I.empty

null :: ContiguousU varr => Map karr varr k v -> Bool
null (Map _ vals) = I.null vals

singleton :: (ContiguousU karr, Element karr k, ContiguousU varr, Element varr v) => k -> v -> Map karr varr k v
singleton k v = Map
  ( runST $ do
      arr <- I.new 1
      I.write arr 0 k
      I.unsafeFreeze arr
  )
  ( runST $ do
      arr <- I.new 1
      I.write arr 0 v
      I.unsafeFreeze arr
  )

equals :: (ContiguousU karr, Element karr k, Eq k, ContiguousU varr, Element varr v, Eq v) => Map karr varr k v -> Map karr varr k v -> Bool
equals (Map k1 v1) (Map k2 v2) = I.equals k1 k2 && I.equals v1 v2

compare :: (ContiguousU karr, Element karr k, Ord k, ContiguousU varr, Element varr v, Ord v) => Map karr varr k v -> Map karr varr k v -> Ordering
compare m1 m2 = P.compare (toList m1) (toList m2)

fromListWithN :: (ContiguousU karr, Element karr k, Ord k, ContiguousU varr, Element varr v) => (v -> v -> v) -> Int -> [(k,v)] -> Map karr varr k v
fromListWithN combine n xs =
  case xs of
    [] -> empty
    (k,v) : ys ->
      let (leftovers, result) = fromAscListWith combine (max 1 n) k v ys
       in concatWith combine (result : P.map (uncurry singleton) leftovers)

fromListN :: (ContiguousU karr, Element karr k, Ord k, ContiguousU varr, Element varr v)
  => Int
  -> [(k,v)]
  -> Map karr varr k v
{-# INLINABLE fromListN #-}
fromListN n xs = runST $ do
  (ks,vs) <- mutableArraysFromPairs (max n 1) xs
  unsafeFreezeZip ks vs

mutableArraysFromPairs :: forall s karr varr k v. (ContiguousU karr, Element karr k, Ord k, ContiguousU varr, Element varr v)
  => Int -- must be at least one
  -> [(k,v)]
  -> ST s (Mutable karr s k, Mutable varr s v)
{-# INLINABLE mutableArraysFromPairs #-}
mutableArraysFromPairs n xs = do
  let go :: Int -> Int -> Mutable karr s k -> Mutable varr s v -> [(k,v)] -> ST s (Int, Mutable karr s k, Mutable varr s v)
      go !ix !_ !ks !vs [] = return (ix,ks,vs)
      go !ix !len !ks !vs ((k,v) : ys) = if ix < len
        then do
          I.write ks ix k
          I.write vs ix v
          go (ix + 1) len ks vs ys
        else do
          let len' = len * 2
          ks' <- I.new len'
          vs' <- I.new len'
          I.copyMut ks' 0 (I.sliceMut ks 0 len)
          I.copyMut vs' 0 (I.sliceMut vs 0 len)
          I.write ks' ix k
          I.write vs' ix v
          go (ix + 1) len' ks' vs' ys
  ks0 <- I.new n
  vs0 <- I.new n
  (len,ks',vs') <- go 0 n ks0 vs0 xs
  ksFinal <- I.resize ks' len
  vsFinal <- I.resize vs' len
  return (ksFinal,vsFinal)

fromList :: (ContiguousU karr, Element karr k, Ord k, ContiguousU varr, Element varr v) => [(k,v)] -> Map karr varr k v
fromList = fromListN 8

fromListAppendN :: (ContiguousU karr, Element karr k, Ord k, ContiguousU varr, Element varr v, Semigroup v) => Int -> [(k,v)] -> Map karr varr k v
fromListAppendN = fromListWithN (SG.<>)

fromListAppend :: (ContiguousU karr, Element karr k, Ord k, ContiguousU varr, Element varr v, Semigroup v) => [(k,v)] -> Map karr varr k v
fromListAppend = fromListAppendN 1

fromAscListWith :: forall karr varr k v. (ContiguousU karr, Element karr k, Ord k, ContiguousU varr, Element varr v)
  => (v -> v -> v)
  -> Int -- initial size of buffer, must be 1 or higher
  -> k -- first key
  -> v -- first value
  -> [(k,v)] -- elements
  -> ([(k,v)], Map karr varr k v)
fromAscListWith combine !n !k0 !v0 xs0 = runST $ do
  keys0 <- I.new n
  vals0 <- I.new n
  I.write keys0 0 k0
  I.write vals0 0 v0
  let go :: forall s. Int -> k -> Int -> Mutable karr s k -> Mutable varr s v -> [(k,v)] -> ST s ([(k,v)], Map karr varr k v)
      go !ix !_ !sz !theKeys !vals [] = if ix == sz
        then do
          arrKeys <- I.unsafeFreeze theKeys
          arrVals <- I.unsafeFreeze vals
          return ([],Map arrKeys arrVals)
        else do
          keys' <- I.resize theKeys ix
          arrKeys <- I.unsafeFreeze keys'
          vals' <- I.resize vals ix
          arrVals <- I.unsafeFreeze vals'
          return ([],Map arrKeys arrVals)
      go !ix !old !sz !theKeys !vals ((k,v) : xs) = if ix < sz
        then case P.compare k old of
          GT -> do
            I.write theKeys ix k
            I.write vals ix v
            go (ix + 1) k sz theKeys vals xs
          EQ -> do
            oldVal <- I.read vals (ix - 1)
            let !newVal = combine oldVal v
            I.write vals (ix - 1) newVal
            go ix k sz theKeys vals xs
          LT -> do
            keys' <- I.resize theKeys ix
            arrKeys <- I.unsafeFreeze keys'
            vals' <- I.resize vals ix
            arrVals <- I.unsafeFreeze vals'
            return ((k,v) : xs,Map arrKeys arrVals)
        else do
          let sz' = sz * 2
          keys' <- I.resize theKeys sz'
          vals' <- I.resize vals sz'
          go ix old sz' keys' vals' ((k,v) : xs)
  go 1 k0 n keys0 vals0 xs0


map :: (ContiguousU varr, ContiguousU warr, Element varr v, Element warr w)
  => (v -> w)
  -> Map karr varr k v
  -> Map karr warr k w
map f (Map k v) = Map k (I.map f v)

-- | /O(n)/ Map over the elements with access to their corresponding keys.
mapWithKey :: forall karr varr k v w. (ContiguousU karr, Element karr k, ContiguousU varr, Element varr v, Element varr w)
  => (k -> v -> w)
  -> Map karr varr k v
  -> Map karr varr k w
{-# INLINEABLE mapWithKey #-}
mapWithKey f (Map ks vs) = runST $ do
  let !sz = I.size vs
  !(karr :: Mutable karr s k) <- I.new sz
  !(varr :: Mutable varr s w) <- I.new sz
  let go !ix = if ix < sz
        then do
          k <- I.indexM ks ix
          a <- I.indexM vs ix
          I.write varr ix (f k a)
          I.write karr ix k
          go (ix + 1)
        else return ix
  dstLen <- go 0
  ksFinal <- I.resize karr dstLen >>= I.unsafeFreeze
  vsFinal <- I.resize varr dstLen >>= I.unsafeFreeze
  return (Map ksFinal vsFinal)

-- | /O(n)/ Drop elements for which the predicate returns 'Nothing'.
mapMaybe :: forall karr varr k v w. (ContiguousU karr, Element karr k, ContiguousU varr, Element varr v, Element varr w)
  => (v -> Maybe w)
  -> Map karr varr k v
  -> Map karr varr k w
{-# INLINE mapMaybe #-}
mapMaybe f (Map ks vs) = runST $ do
  let !sz = I.size vs
  !(karr :: Mutable karr s k) <- I.new sz
  !(varr :: Mutable varr s w) <- I.new sz
  let go !ixSrc !ixDst = if ixSrc < sz
        then do
          a <- I.indexM vs ixSrc
          case f a of
            Nothing -> go (ixSrc + 1) ixDst
            Just b -> do
              I.write varr ixDst b
              I.write karr ixDst =<< I.indexM ks ixSrc
              go (ixSrc + 1) (ixDst + 1)
        else return ixDst
  dstLen <- go 0 0
  ksFinal <- I.resize karr dstLen >>= I.unsafeFreeze
  vsFinal <- I.resize varr dstLen >>= I.unsafeFreeze
  return (Map ksFinal vsFinal)

-- | /O(n)/ Drop elements for which the predicate returns 'Nothing'.
mapMaybeP :: forall karr varr m k v w. (PrimMonad m, ContiguousU karr, Element karr k, ContiguousU varr, Element varr v, Element varr w)
  => (v -> m (Maybe w))
  -> Map karr varr k v
  -> m (Map karr varr k w)
{-# INLINE mapMaybeP #-}
mapMaybeP f (Map ks vs) = do
  let !sz = I.size vs
  !(karr :: Mutable karr (PrimState m) k) <- I.new sz
  !(varr :: Mutable varr (PrimState m) w) <- I.new sz
  let go !ixSrc !ixDst = if ixSrc < sz
        then do
          a <- I.indexM vs ixSrc
          f a >>= \case
            Nothing -> go (ixSrc + 1) ixDst
            Just b -> do
              I.write varr ixDst b
              I.write karr ixDst =<< I.indexM ks ixSrc
              go (ixSrc + 1) (ixDst + 1)
        else return ixDst
  dstLen <- go 0 0
  ksFinal <- I.resize karr dstLen >>= I.unsafeFreeze
  vsFinal <- I.resize varr dstLen >>= I.unsafeFreeze
  return (Map ksFinal vsFinal)

-- | /O(n)/ Drop elements for which the predicate returns 'Nothing'.
mapMaybeWithKey :: forall karr varr k v w. (ContiguousU karr, Element karr k, ContiguousU varr, Element varr v, Element varr w)
  => (k -> v -> Maybe w)
  -> Map karr varr k v
  -> Map karr varr k w
{-# INLINEABLE mapMaybeWithKey #-}
mapMaybeWithKey f (Map ks vs) = runST $ do
  let !sz = I.size vs
  !(karr :: Mutable karr s k) <- I.new sz
  !(varr :: Mutable varr s w) <- I.new sz
  let go !ixSrc !ixDst = if ixSrc < sz
        then do
          k <- I.indexM ks ixSrc
          a <- I.indexM vs ixSrc
          case f k a of
            Nothing -> go (ixSrc + 1) ixDst
            Just !b -> do
              I.write varr ixDst b
              I.write karr ixDst k
              go (ixSrc + 1) (ixDst + 1)
        else return ixDst
  dstLen <- go 0 0
  ksFinal <- I.resize karr dstLen >>= I.unsafeFreeze
  vsFinal <- I.resize varr dstLen >>= I.unsafeFreeze
  return (Map ksFinal vsFinal)

showsPrec :: (ContiguousU karr, Element karr k, Show k, ContiguousU varr, Element varr v, Show v) => Int -> Map karr varr k v -> ShowS
showsPrec p xs = showParen (p > 10) $
  showString "fromList " . shows (toList xs)

toList :: (ContiguousU karr, Element karr k, ContiguousU varr, Element varr v) => Map karr varr k v -> [(k,v)]
toList = foldrWithKey (\k v xs -> (k,v) : xs) []

foldrWithKey :: (ContiguousU karr, Element karr k, ContiguousU varr, Element varr v)
  => (k -> v -> b -> b)
  -> b
  -> Map karr varr k v
  -> b
foldrWithKey f z (Map theKeys vals) =
  let !sz = I.size vals
      go !i
        | i == sz = z
        | otherwise =
            let !(# k #) = I.index# theKeys i
                !(# v #) = I.index# vals i
             in f k v (go (i + 1))
   in go 0

foldMapWithKey :: (ContiguousU karr, Element karr k, ContiguousU varr, Element varr v, Monoid m)
  => (k -> v -> m)
  -> Map karr varr k v
  -> m
foldMapWithKey f (Map theKeys vals) =
  let !sz = I.size vals
      go !i
        | i == sz = mempty
        | otherwise =
            let !(# k #) = I.index# theKeys i
                !(# v #) = I.index# vals i
             in mappend (f k v) (go (i + 1))
   in go 0

adjustMany :: forall karr varr m k v a. (ContiguousU karr, Element karr k, ContiguousU varr, Element varr v, PrimMonad m, Ord k)
  => ((k -> (v -> m v) -> m ()) -> m a) -- Callback that takes a modify function
  -> Map karr varr k v
  -> m (Map karr varr k v, a)
{-# INLINABLE adjustMany #-}
adjustMany f (Map theKeys theVals) = do
  mvals <- I.thaw (I.slice theVals 0 (I.size theVals))
  let g :: k -> (v -> m v) -> m ()
      g !k updateVal =
        let go !start !end = if end < start
              then pure ()
              else
                let !mid = div (end + start) 2
                    !(# v #) = I.index# theKeys mid
                 in case P.compare k v of
                      LT -> go start (mid - 1)
                      EQ -> do
                        r <- I.read mvals mid
                        r' <- updateVal r
                        I.write mvals mid r'
                      GT -> go (mid + 1) end
         in go 0 (I.size theVals - 1)
  r <- f g
  rvals <- I.unsafeFreeze mvals
  pure (Map theKeys rvals, r)

adjustManyInline :: forall karr varr m k v a. (ContiguousU karr, Element karr k, ContiguousU varr, Element varr v, PrimMonad m, Ord k)
  => ((k -> (v -> m v) -> m ()) -> m a) -- Callback that takes a modify function
  -> Map karr varr k v
  -> m (Map karr varr k v, a)
{-# INLINE adjustManyInline #-}
adjustManyInline f (Map theKeys theVals) = do
  mvals <- I.thaw (I.slice theVals 0 (I.size theVals))
  let g :: k -> (v -> m v) -> m ()
      g !k updateVal =
        let go !start !end = if end < start
              then pure ()
              else
                let !mid = div (end + start) 2
                    !(# v #) = I.index# theKeys mid
                 in case P.compare k v of
                      LT -> go start (mid - 1)
                      EQ -> do
                        r <- I.read mvals mid
                        r' <- updateVal r
                        I.write mvals mid r'
                      GT -> go (mid + 1) end
         in go 0 (I.size theVals - 1)
  r <- f g
  rvals <- I.unsafeFreeze mvals
  pure (Map theKeys rvals, r)

concat :: (ContiguousU karr, Element karr k, Ord k, ContiguousU varr, Element varr v, Semigroup v) => [Map karr varr k v] -> Map karr varr k v
concat = concatWith (SG.<>)

concatWith :: forall karr varr k v. (ContiguousU karr, Element karr k, Ord k, ContiguousU varr, Element varr v)
  => (v -> v -> v)
  -> [Map karr varr k v]
  -> Map karr varr k v
concatWith combine = C.concatSized size empty (appendWith combine)

intersectionsWith :: (ContiguousU karr, Element karr k, ContiguousU varr, Element varr v, Ord k)
  => (v -> v -> v)
  -> NonEmpty (Map karr varr k v)
  -> Map karr varr k v
intersectionsWith f = C.concatSized1 size (intersectionWith f)

appendRightBiased :: (ContiguousU karr, Element karr k, ContiguousU varr, Element varr v, Ord k) => Map karr varr k v -> Map karr varr k v -> Map karr varr k v
appendRightBiased = appendWith const

appendWithKey :: (ContiguousU karr, Element karr k, ContiguousU varr, Element varr v, Ord k)
  => (k -> v -> v -> v) -> Map karr varr k v -> Map karr varr k v -> Map karr varr k v
appendWithKey combine (Map ksA vsA) (Map ksB vsB) =
  case unionArrWith combine ksA vsA ksB vsB of
    (k,v) -> Map k v
  
appendWith :: (ContiguousU karr, Element karr k, ContiguousU varr, Element varr v, Ord k)
  => (v -> v -> v) -> Map karr varr k v -> Map karr varr k v -> Map karr varr k v
appendWith combine (Map ksA vsA) (Map ksB vsB) =
  case unionArrWith (\_ x y -> combine x y) ksA vsA ksB vsB of
    (k,v) -> Map k v
  
append :: (ContiguousU karr, Element karr k, ContiguousU varr, Element varr v, Ord k, Semigroup v)
  => Map karr varr k v -> Map karr varr k v -> Map karr varr k v
append (Map ksA vsA) (Map ksB vsB) =
  case unionArrWith (\_ x y -> x SG.<> y) ksA vsA ksB vsB of
    (k,v) -> Map k v
  
intersectionWith :: forall k v w x karr varr warr xarr.
     (ContiguousU karr, Element karr k, ContiguousU varr, Element varr v, ContiguousU warr, Element warr w, ContiguousU xarr, Element xarr x, Ord k)
  => (v -> w -> x)
  -> Map karr varr k v
  -> Map karr warr k w
  -> Map karr xarr k x
intersectionWith f s1@(Map karr1 varr1) s2@(Map karr2 varr2)
  | sz1 == 0 = empty
  | sz2 == 0 = empty
  | otherwise = runST $ do
      let maxSz = min sz1 sz2
      kdst <- I.new maxSz
      vdst <- I.new maxSz
      let go !ix1 !ix2 !dstIx = if ix2 < sz2 && ix1 < sz1
            then do
              k1 <- I.indexM karr1 ix1
              k2 <- I.indexM karr2 ix2
              case P.compare k1 k2 of
                EQ -> do
                  v1 <- I.indexM varr1 ix1
                  v2 <- I.indexM varr2 ix2
                  I.write kdst dstIx k1
                  I.write vdst dstIx (f v1 v2)
                  go (ix1 + 1) (ix2 + 1) (dstIx + 1)
                LT -> go (ix1 + 1) ix2 dstIx
                GT -> go ix1 (ix2 + 1) dstIx
            else return dstIx
      dstSz <- go 0 0 0
      kdstFrozen <- I.resize kdst dstSz >>= I.unsafeFreeze
      vdstFrozen <- I.resize vdst dstSz >>= I.unsafeFreeze
      return (Map kdstFrozen vdstFrozen)
  where
    !sz1 = size s1
    !sz2 = size s2

unionArrWith :: forall karr varr k v. (ContiguousU karr, Element karr k, Ord k, ContiguousU varr, Element varr v)
  => (k -> v -> v -> v)
  -> karr k -- keys a
  -> varr v -- values a
  -> karr k -- keys b
  -> varr v -- values b
  -> (karr k, varr v)
unionArrWith combine keysA valsA keysB valsB
  | I.size valsA < 1 = (keysB,valsB)
  | I.size valsB < 1 = (keysA,valsA)
  | otherwise = runST $ do
      let !szA = I.size valsA
          !szB = I.size valsB
      !(keysDst :: Mutable karr s k) <- I.new (szA + szB)
      !(valsDst :: Mutable varr s v) <- I.new (szA + szB)
      let go !ixA !ixB !ixDst = if ixA < szA
            then if ixB < szB
              then do
                let !keyA = I.index keysA ixA
                    !keyB = I.index keysB ixB
                    !(# valA #) = I.index# valsA ixA
                    !(# valB #) = I.index# valsB ixB
                case P.compare keyA keyB of
                  EQ -> do
                    I.write keysDst ixDst keyA
                    let r = combine keyA valA valB
                    I.write valsDst ixDst r
                    go (ixA + 1) (ixB + 1) (ixDst + 1)
                  LT -> do
                    I.write keysDst ixDst keyA
                    I.write valsDst ixDst valA
                    go (ixA + 1) ixB (ixDst + 1)
                  GT -> do
                    I.write keysDst ixDst keyB
                    I.write valsDst ixDst valB
                    go ixA (ixB + 1) (ixDst + 1)
              else do
                I.copy keysDst ixDst (I.slice keysA ixA (szA - ixA))
                I.copy valsDst ixDst (I.slice valsA ixA (szA - ixA))
                return (ixDst + (szA - ixA))
            else if ixB < szB
              then do
                I.copy keysDst ixDst (I.slice keysB ixB (szB - ixB))
                I.copy valsDst ixDst (I.slice valsB ixB (szB - ixB))
                return (ixDst + (szB - ixB))
              else return ixDst
      !total <- go 0 0 0
      !keysFinal <- I.resize keysDst total
      !valsFinal <- I.resize valsDst total
      liftA2 (,) (I.unsafeFreeze keysFinal) (I.unsafeFreeze valsFinal)
 
lookup :: forall karr varr k v.
     (ContiguousU karr, Element karr k, Ord k, ContiguousU varr, Element varr v)
  => k
  -> Map karr varr k v
  -> Maybe v
{-# INLINEABLE lookup #-}
lookup a (Map arr vals) = go 0 (I.size vals - 1) where
  go :: Int -> Int -> Maybe v
  go !start !end = if end < start
    then Nothing
    else
      let !mid = div (end + start) 2
          !(# v #) = I.index# arr mid
       in case P.compare a v of
            LT -> go start (mid - 1)
            EQ -> case I.index# vals mid of
              (# r #) -> Just r
            GT -> go (mid + 1) end

size :: (ContiguousU varr, Element varr v) => Map karr varr k v -> Int
size (Map _ arr) = I.size arr

-- This may have less constraints than size
sizeKeys :: (ContiguousU karr, Element karr k) => Map karr varr k v -> Int
sizeKeys (Map arr _) = I.size arr

-- | Sort and deduplicate the key array, preserving the last value associated
-- with each key. The argument arrays may not be reused after being passed
-- to this function. This function is only unsafe because of the requirement
-- that the arguments not be reused. If the arrays do not match in size, the
-- larger one will be truncated to the length of the shorter one.
unsafeFreezeZip :: (ContiguousU karr, Element karr k, Ord k, ContiguousU varr, Element varr v)
  => Mutable karr s k
  -> Mutable varr s v
  -> ST s (Map karr varr k v)
unsafeFreezeZip keys0 vals0 = do
  (keys1,vals1) <- sortUniqueTaggedMutable keys0 vals0
  keys2 <- I.unsafeFreeze keys1
  vals2 <- I.unsafeFreeze vals1
  return (Map keys2 vals2)
{-# INLINEABLE unsafeFreezeZip #-}

-- | There are two preconditions:
--
-- * The array of keys is sorted
-- * The array of keys and the array of values have the same length.
--
-- If either of these conditions is not met, this function will introduce
-- undefined behavior or segfaults.
unsafeZipPresorted :: (ContiguousU karr, Element karr k, ContiguousU varr, Element varr v)
  => karr k -- array of keys, must already be sorted
  -> varr v -- array of values
  -> Map karr varr k v
unsafeZipPresorted = Map

foldlWithKeyM' :: forall karr varr k v m b. (Monad m, ContiguousU karr, Element karr k, ContiguousU varr, Element varr v)
  => (b -> k -> v -> m b)
  -> b
  -> Map karr varr k v
  -> m b
foldlWithKeyM' f b0 (Map ks vs) = go 0 b0
  where
  !len = I.size vs
  go :: Int -> b -> m b
  go !ix !acc = if ix < len
    then
      let !(# k #) = I.index# ks ix
          !(# v #) = I.index# vs ix
       in f acc k v >>= go (ix + 1)
    else return acc
{-# INLINEABLE foldlWithKeyM' #-}

foldrWithKeyM' :: forall karr varr k v m b. (Monad m, ContiguousU karr, Element karr k, ContiguousU varr, Element varr v)
  => (k -> v -> b -> m b)
  -> b
  -> Map karr varr k v
  -> m b
foldrWithKeyM' f b0 (Map ks vs) = go (I.size vs - 1) b0
  where
  go :: Int -> b -> m b
  go !ix !acc = if ix >= 0
    then
      let !(# k #) = I.index# ks ix
          !(# v #) = I.index# vs ix
       in f k v acc >>= go (ix - 1)
    else return acc
{-# INLINEABLE foldrWithKeyM' #-}

foldlMapWithKeyM' :: forall karr varr k v m b. (Monad m, ContiguousU karr, Element karr k, ContiguousU varr, Element varr v, Monoid b)
  => (k -> v -> m b)
  -> Map karr varr k v
  -> m b
foldlMapWithKeyM' f (Map ks vs) = go 0 mempty
  where
  !len = I.size vs
  go :: Int -> b -> m b
  go !ix !accl = if ix < len
    then
      let !(# k #) = I.index# ks ix
          !(# v #) = I.index# vs ix
       in do
         accr <- f k v
         go (ix + 1) (mappend accl accr)
    else return accl
{-# INLINEABLE foldlMapWithKeyM' #-}

traverse :: (Applicative m, ContiguousU karr, Element karr k, ContiguousU varr, Element varr v, Element varr w)
  => (v -> m w)
  -> Map karr varr k v
  -> m (Map karr varr k w)
{-# INLINEABLE traverse #-}
traverse f (Map theKeys theVals) =
  fmap (Map theKeys) (I.traverse f theVals)

traverseWithKey :: (ContiguousU karr, Element karr k, ContiguousU varr, Element varr v, Element varr v', Applicative f)
  => (k -> v -> f v')
  -> Map karr varr k v
  -> f (Map karr varr k v')
{-# INLINEABLE traverseWithKey #-}
traverseWithKey f (Map theKeys theVals) = fmap (Map theKeys)
  $ I.itraverse (\i v -> f (I.index theKeys i) v) theVals

traverseWithKey_ :: forall karr varr k v m b. (Applicative m, ContiguousU karr, Element karr k, ContiguousU varr, Element varr v)
  => (k -> v -> m b)
  -> Map karr varr k v
  -> m ()
traverseWithKey_ f (Map ks vs) = go 0
  where
  !len = I.size vs
  go :: Int -> m ()
  go !ix = if ix < len
    then
      let !(# k #) = I.index# ks ix
          !(# v #) = I.index# vs ix
       in f k v *> go (ix + 1)
    else pure ()
{-# INLINEABLE traverseWithKey_ #-}

foldrMapWithKeyM' :: forall karr varr k v m b. (Monad m, ContiguousU karr, Element karr k, ContiguousU varr, Element varr v, Monoid b)
  => (k -> v -> m b)
  -> Map karr varr k v
  -> m b
foldrMapWithKeyM' f (Map ks vs) = go (I.size vs - 1) mempty
  where
  go :: Int -> b -> m b
  go !ix !accr = if ix >= 0
    then
      let !(# k #) = I.index# ks ix
          !(# v #) = I.index# vs ix
       in do
         accl <- f k v
         go (ix - 1) (mappend accl accr)
    else return accr
{-# INLINEABLE foldrMapWithKeyM' #-}

foldMapWithKey' :: forall karr varr k v m. (ContiguousU karr, Element karr k, ContiguousU varr, Element varr v, Monoid m)
  => (k -> v -> m)
  -> Map karr varr k v
  -> m
foldMapWithKey' f (Map ks vs) = go 0 mempty
  where
  !len = I.size vs
  go :: Int -> m -> m
  go !ix !accl = if ix < len
    then 
      let !(# k #) = I.index# ks ix
          !(# v #) = I.index# vs ix
       in go (ix + 1) (mappend accl (f k v))
    else accl
{-# INLINEABLE foldMapWithKey' #-}

foldlWithKey' :: forall karr varr k v b. (ContiguousU karr, Element karr k, ContiguousU varr, Element varr v)
  => (b -> k -> v -> b) 
  -> b
  -> Map karr varr k v
  -> b
foldlWithKey' f b0 (Map ks vs) = go 0 b0
  where
  !len = I.size vs
  go :: Int -> b -> b
  go !ix !acc = if ix < len
    then 
      let !(# k #) = I.index# ks ix
          !(# v #) = I.index# vs ix
       in go (ix + 1) (f acc k v)
    else acc
{-# INLINEABLE foldlWithKey' #-}

foldrWithKey' :: forall karr varr k v b. (ContiguousU karr, Element karr k, ContiguousU varr, Element varr v)
  => (k -> v -> b -> b)
  -> b
  -> Map karr varr k v
  -> b
foldrWithKey' f b0 (Map ks vs) = go (I.size vs - 1) b0
  where
  go :: Int -> b -> b
  go !ix !acc = if ix >= 0
    then
      let !(# k #) = I.index# ks ix
          !(# v #) = I.index# vs ix
       in go (ix - 1) (f k v acc)
    else acc
{-# INLINEABLE foldrWithKey' #-}

-- The algorithm used here is good when the subset is small, but
-- when the subset is large, it is worse that just walking the map.
restrict :: forall karr varr k v. (ContiguousU karr, Element karr k, ContiguousU varr, Element varr v, Ord k)
  => Map karr varr k v
  -> Set karr k
  -> Map karr varr k v
restrict m@(Map ks vs) (Set rs)
  | I.same ks rs = m
  | otherwise = stage1 0
  where
  szMap = I.size vs
  szSet = I.size rs
  szMin = min szMap szSet
  -- Locate the first difference between the two. This stage is useful
  -- because, in the case that the subset perfectly matches the keys,
  -- we do not need to do any copying.
  stage1 :: Int -> Map karr varr k v
  stage1 !ix = if ix < szMin
    then
      let !(# k #) = I.index# ks ix
          !(# r #) = I.index# rs ix
       in if k == r
            then stage1 (ix + 1)
            else stage2 ix
    else if szMin == szMap
      then m
      else Map rs vs
  -- In stage two, we walk the map and the set with possibly differing
  -- indices, writing each matching key (along with its value) into
  -- the result map.
  stage2 :: Int -> Map karr varr k v
  stage2 !ix = runST $ do
    ksMut <- I.new szMin
    vsMut <- I.new szMin
    I.copy ksMut 0 (I.slice ks 0 ix)
    I.copy vsMut 0 (I.slice vs 0 ix)
    let -- TODO: Turn this into a galloping search. It would
        -- probably be worth trying this out on
        -- Data.Set.Internal.intersection first.
        go !ixRes !ixm !ixs = if ixm < szMin && ixs < szMin
          then do
            k <- I.indexM ks ixm
            r <- I.indexM rs ixs
            case P.compare k r of
              EQ -> do
                I.write ksMut ixRes k
                I.write vsMut ixRes =<< I.indexM vs ixm
                go (ixRes + 1) (ixm + 1) (ixs + 1)
              LT -> go ixRes (ixm + 1) ixs
              GT -> go ixRes ixm (ixs + 1)
          else return ixRes
    total <- go ix ix ix
    ks' <- I.resize ksMut total >>= I.unsafeFreeze
    vs' <- I.resize vsMut total >>= I.unsafeFreeze
    return (Map ks' vs')
{-# INLINEABLE restrict #-}

fromSet :: (ContiguousU karr, Element karr k, ContiguousU varr, Element varr v)
  => (k -> v)
  -> Set karr k
  -> Map karr varr k v
fromSet f (Set arr) = Map arr (I.map f arr)
{-# INLINE fromSet #-}

fromSetP :: (PrimMonad m, ContiguousU karr, Element karr k, ContiguousU varr, Element varr v)
  => (k -> m v)
  -> Set karr k
  -> m (Map karr varr k v)
fromSetP f (Set arr) = fmap (Map arr) (I.traverseP f arr)
{-# INLINE fromSetP #-}

keys :: Map karr varr k v -> Set karr k
keys (Map k _) = Set k

elems :: Map karr varr k v -> varr v
elems (Map _ v) = v

rnf :: (ContiguousU karr, Element karr k, ContiguousU varr, Element varr v, NFData k, NFData v)
  => Map karr varr k v
  -> ()
rnf (Map k v) = seq (I.rnf k) (seq (I.rnf v) ())

