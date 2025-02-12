{-# LANGUAGE CPP #-}
{-# LANGUAGE TemplateHaskell #-}

-- |
-- Copyright:   (c) 2022 Andrew Lelechenko
-- Licence:     BSD3
-- Maintainer:  Andrew Lelechenko <andrew.lelechenko@gmail.com>
#ifdef aarch64_HOST_ARCH
{-# OPTIONS_GHC -Wno-unused-imports -Wno-unused-top-binds #-}
#endif

module Data.Text.Builder.Linear.Dec (
  (|>$),
  ($<|),
) where

#include "MachDeps.h"

import Data.Bits (Bits (..), FiniteBits (..))
import Data.Int (Int16, Int32, Int8)
import Data.Text.Array qualified as A
import Data.Word (Word16, Word32, Word8)
import GHC.Exts (Addr#, Int (..), Ptr (..), dataToTag#, (>=#))
import GHC.Ptr (plusPtr)
import GHC.ST (ST)
import Numeric.QuoteQuot (assumeNonNegArg, astQuot, quoteAST, quoteQuot)

import Data.Text.Builder.Linear.Core

-- | Append decimal number.
(|>$) ∷ (Integral a, FiniteBits a) ⇒ Buffer ⊸ a → Buffer

infixl 6 |>$
buffer |>$ n =
  appendBounded
    (maxDecLen n)
    (\dst dstOff → unsafeAppendDec dst dstOff n)
    buffer
{-# INLINEABLE (|>$) #-}

-- | Prepend decimal number.
($<|) ∷ (Integral a, FiniteBits a) ⇒ a → Buffer ⊸ Buffer

infixr 6 $<|
n $<| buffer =
  prependBounded
    (maxDecLen n)
    (\dst dstOff → unsafePrependDec dst dstOff n)
    (\dst dstOff → unsafeAppendDec dst dstOff n)
    buffer
{-# INLINEABLE ($<|) #-}

-- | ceiling (fbs a * logBase 10 2) < ceiling (fbs a * 5 / 16) < 1 + floor (fbs a * 5 / 16)
maxDecLen ∷ FiniteBits a ⇒ a → Int
maxDecLen a
  | isSigned a = 2 + (finiteBitSize a * 5) `shiftR` 4
  | otherwise = 1 + (finiteBitSize a * 5) `shiftR` 4
{-# INLINEABLE maxDecLen #-}

exactDecLen ∷ (Integral a, FiniteBits a) ⇒ a → Int
exactDecLen n
  | n < 0 =
      go 2 (complement n + fromIntegral (I# (dataToTag# (n > bit (finiteBitSize n - 1)))))
  | otherwise =
      go 1 n
  where
    go ∷ (Integral a, FiniteBits a) ⇒ Int → a → Int
    go acc k
      | finiteBitSize k >= 30, k >= 1000000000 = go (acc + 9) (quotBillion k)
      | otherwise = acc + goInt (fromIntegral k)

    goInt l@(I# l#)
      | l >= 1e5 = 5 + I# (l# >=# 100000000#) + I# (l# >=# 10000000#) + I# (l# >=# 1000000#)
      | otherwise = I# (l# >=# 10000#) + I# (l# >=# 1000#) + I# (l# >=# 100#) + I# (l# >=# 10#)
{-# INLINEABLE exactDecLen #-}

unsafeAppendDec ∷ (Integral a, FiniteBits a) ⇒ A.MArray s → Int → a → ST s Int
unsafeAppendDec marr off n = unsafePrependDec marr (off + exactDecLen n) n
{-# INLINEABLE unsafeAppendDec #-}

unsafePrependDec ∷ ∀ s a. (Integral a, FiniteBits a) ⇒ A.MArray s → Int → a → ST s Int
unsafePrependDec marr !off n
  | n < 0
  , n == bit (finiteBitSize n - 1) = do
      A.unsafeWrite marr (off - 1) (fromIntegral (48 + minBoundLastDigit n))
      go (off - 2) (abs (bit (finiteBitSize n - 1) `quot` 10)) >>= sign
  | n == 0 = do
      A.unsafeWrite marr (off - 1) 0x30 >> pure 1
  | otherwise = go (off - 1) (abs n) >>= sign
  where
    sign !o
      | n > 0 = pure (off - o)
      | otherwise = do
          A.unsafeWrite marr (o - 1) 0x2d -- '-'
          pure (off - o + 1)

    go ∷ Int → a → ST s Int
    go o k
      | k >= 10 = do
          let (q, r) = quotRem100 k
          A.copyFromPointer marr (o - 1) (Ptr digits `plusPtr` (fromIntegral r `shiftL` 1)) 2
          if k < 100 then pure (o - 1) else go (o - 2) q
      | otherwise = do
          A.unsafeWrite marr o (fromIntegral (48 + k))
          pure o

    digits ∷ Addr#
    digits = "00010203040506070809101112131415161718192021222324252627282930313233343536373839404142434445464748495051525354555657585960616263646566676869707172737475767778798081828384858687888990919293949596979899"#
{-# INLINEABLE unsafePrependDec #-}

minBoundLastDigit ∷ FiniteBits a ⇒ a → Int
minBoundLastDigit a = case finiteBitSize a .&. 4 of
  0 → 8
  1 → 6
  2 → 2
  _ → 4
{-# INLINEABLE minBoundLastDigit #-}

quotRem100 ∷ (Integral a, FiniteBits a) ⇒ a → (a, a)

-- https://gitlab.haskell.org/ghc/ghc/-/issues/22933
#ifdef aarch64_HOST_ARCH
quotRem100 a = a `quotRem` 100
#else
quotRem100 a = let q = quot100 a in (q, a - 100 * q)
#endif
{-# INLINEABLE quotRem100 #-}

quot100 ∷ (Integral a, FiniteBits a) ⇒ a → a
quot100 a = case (finiteBitSize a, isSigned a) of
  (64, True)
    | finiteBitSize (0 ∷ Int) == 64 →
        cast $$(quoteAST $ assumeNonNegArg $ astQuot (100 ∷ Int))
  (64, False)
    | finiteBitSize (0 ∷ Word) == 64 →
        cast $$(quoteQuot (100 ∷ Word))
  (32, True) → cast $$(quoteAST $ assumeNonNegArg $ astQuot (100 ∷ Int32))
  (32, False) → cast $$(quoteQuot (100 ∷ Word32))
  (16, True) → cast $$(quoteAST $ assumeNonNegArg $ astQuot (100 ∷ Int16))
  (16, False) → cast $$(quoteQuot (100 ∷ Word16))
  (8, True) → cast $$(quoteAST $ assumeNonNegArg $ astQuot (100 ∷ Int8))
  (8, False) → cast $$(quoteQuot (100 ∷ Word8))
  _ → a `quot` 100
  where
    cast ∷ (Integral a, Integral b) ⇒ (b → b) → a
    cast f = fromIntegral (f (fromIntegral a))
{-# INLINEABLE quot100 #-}

quotBillion ∷ (Integral a, FiniteBits a) ⇒ a → a
#ifdef aarch64_HOST_ARCH
quotBillion a = a `quot` 1e9
#else
quotBillion a = case (finiteBitSize a, isSigned a) of
  (64, True)
    | finiteBitSize (0 :: Int) == 64
    → cast $$(quoteAST $ assumeNonNegArg $ astQuot (1e9 :: Int))
  (64, False)
    | finiteBitSize (0 :: Word) == 64
    → cast $$(quoteQuot (1e9 :: Word))
  (32, True)  → cast $$(quoteAST $ assumeNonNegArg $ astQuot (1e9 :: Int32))
  (32, False) → cast $$(quoteQuot (1e9 :: Word32))
  _ → a `quot` 1e9
  where
    cast :: (Integral a, Integral b) => (b → b) → a
    cast f = fromIntegral (f (fromIntegral a))
#endif
{-# INLINEABLE quotBillion #-}
