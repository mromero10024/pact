{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      :  Pact.Types.PureBlake2
-- Copyright   :  (C) 2016 Stuart Popejoy
-- License     :  BSD-style (see the file LICENSE)
-- Maintainer  :  Stuart Popejoy <stuart@kadena.io>
--
-- Pure implementation of BLAKE2b for use in GHCJS.
-- Adapted from reference C code in RFC 7693.
--

module Pact.Types.Blake2b where

import Data.Word
import Data.Bits
import Data.ByteString as B (ByteString,index,pack,unpack,length,take,splitAt,null)
import Data.Vector as V (Vector,(//),(!),fromList,(++))
import Control.Lens ((&))
import Prelude as P
import Numeric
import Data.Monoid
import Control.Monad


-- | state context
data Blake2BCtx = Blake2BCtx
  { _b :: ByteString -- 128 input buffer
  , _h :: V I   --   8 chained state
  , _t0 :: I   --   2 total number of bytes
  , _t1 :: I
  , _c :: Int        -- pointer for b[]
  , _outlen :: Int   -- digest size
  } deriving (Eq,Show)

empty = Blake2BCtx (pack $ replicate 128 0) (mk $ replicate 8 0) 0 0 0 0

type I = Word64
type V = Vector

at :: V a -> Int -> a
at v i = v ! i

upd :: V a -> Int -> a -> V a
upd v i l = v // [(i,l)]

mk :: [a] -> V a
mk = fromList

cat :: V I -> V I -> V I
cat = (V.++)



-- | Cyclic right rotation.
rotr64 :: I -> Int -> I
rotr64 x y = (x `shiftR` y) `xor` (x `shiftL` (64 - y))

-- | Little-endian byte access.

b2b_get64 :: Int -> ByteString -> I
b2b_get64 o p =
  let ix64 i = fromIntegral $ index p (o+i)
  in
        ix64 0               `xor`
       (ix64 1  `shiftL` 8 ) `xor`
       (ix64 2  `shiftL` 16) `xor`
       (ix64 3  `shiftL` 24) `xor`
       (ix64 4  `shiftL` 32) `xor`
       (ix64 5  `shiftL` 40) `xor`
       (ix64 6  `shiftL` 48) `xor`
       (ix64 7  `shiftL` 56)


-- | G Mixing function.
b2b_g :: Int -> Int -> Int -> Int -> I -> I -> V I -> V I
b2b_g a b c d x y v' =
  v' &
  --  v[a] = v[a] + v[b] + x;         \
  (\v -> upd v a $ (v `at` a) + (v `at` b) + x) &
  --  v[d] = rotr64(v[d] `xor` v[a], 32); \
  (\v -> upd v d $ rotr64 ((v `at` d) `xor` (v `at` a)) 32) &
  --  v[c] = v[c] + v[d];             \
  (\v -> upd v c $ (v `at` c) + (v `at` d)) &
  --  v[b] = rotr64(v[b] `xor` v[c], 24); \
  (\v -> upd v b $ rotr64 ((v `at` b) `xor` (v `at` c)) 24) &
  --  v[a] = v[a] + v[b] + y;         \
  (\v -> upd v a $ (v `at` a) + (v `at` b) + y) &
  --  v[d] = rotr64(v[d] `xor` v[a], 16); \
  (\v -> upd v d $ rotr64 ((v `at` d) `xor` (v `at` a)) 16) &
  --  v[c] = v[c] + v[d];             \
  (\v -> upd v c $ (v `at` c) + (v `at` d)) &
  --  v[b] = rotr64(v[b] `xor` v[c], 63); }
  (\v -> upd v b $ rotr64 ((v `at` b) `xor` (v `at` c)) 63)

-- | Initialization Vector.
blake2b_iv :: V I
blake2b_iv = mk [
    0x6A09E667F3BCC908, 0xBB67AE8584CAA73B,
    0x3C6EF372FE94F82B, 0xA54FF53A5F1D36F1,
    0x510E527FADE682D1, 0x9B05688C2B3E6C1F,
    0x1F83D9ABFB41BD6B, 0x5BE0CD19137E2179
    ]

sigma :: V (V Int)
sigma = mk [
        mk [ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 ],
        mk [ 14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3 ],
        mk [ 11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4 ],
        mk [ 7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8 ],
        mk [ 9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13 ],
        mk [ 2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9 ],
        mk [ 12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11 ],
        mk [ 13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10 ],
        mk [ 6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5 ],
        mk [ 10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0 ],
        mk [ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 ],
        mk [ 14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3 ]
        ]


-- | Compression function. "last" flag indicates last block.
blake2b_compress ctx last =
  let
    v1 = (_h ctx `cat` blake2b_iv) &
      (\v -> upd v 12 ((v `at` 12) `xor` _t0 ctx)) &                                  -- low 64 bits of offset
      (\v -> upd v 13 ((v `at` 13) `xor` _t1 ctx)) &                                  -- high 64 bits
      (\v -> if last then upd v 14 (complement (v `at` 14)) else v) -- last block flag set ?
    m = mk $ (`map` [0..15]) $ \i -> b2b_get64 (8 * i) (_b ctx)         -- get little-endian words
    v2 = (\f -> foldl f v1 [0..11]) $ runRound m
    h = mk $ (`map` [0..7]) $ \i ->
          (_h ctx `at` i) `xor` (v2 `at` i) `xor` (v2 `at` (i + 8))
  in ctx { _h = h }

runRound m v i = let sigma' = sigma `at` i
      in v &                -- 12 rounds
        b2b_g 0 4  8 12 (m `at` (sigma' `at`  0)) (m `at` (sigma' `at`  1)) &
        b2b_g 1 5  9 13 (m `at` (sigma' `at`  2)) (m `at` (sigma' `at`  3)) &
        b2b_g 2 6 10 14 (m `at` (sigma' `at`  4)) (m `at` (sigma' `at`  5)) &
        b2b_g 3 7 11 15 (m `at` (sigma' `at`  6)) (m `at` (sigma' `at`  7)) &
        b2b_g 0 5 10 15 (m `at` (sigma' `at`  8)) (m `at` (sigma' `at`  9)) &
        b2b_g 1 6 11 12 (m `at` (sigma' `at` 10)) (m `at` (sigma' `at` 11)) &
        b2b_g 2 7  8 13 (m `at` (sigma' `at` 12)) (m `at` (sigma' `at` 13)) &
        b2b_g 3 4  9 14 (m `at` (sigma' `at` 14)) (m `at` (sigma' `at` 15))

-- | Initialize the hashing context "ctx" with optional key "key".
--      1 <= outlen <= 64 gives the digest size in bytes.
--      Secret key (also <= 64 bytes) is optional (keylen = 0).

blake2b_init :: Word64 -> ByteString -> Either String Blake2BCtx
blake2b_init outlen key
  | outlen == 0 || outlen > 64 = Left $ "outlen must be > 0 and <= 64 bytes" P.++ show outlen
  | B.length key > 64 = Left "Key must be <= 64 bytes"
  | otherwise = Right $
    let keylen :: Word64
        keylen = fromIntegral $ B.length key
        iv = blake2b_iv
    in Blake2BCtx
          -- state, "param block"
          { _h = upd iv 0 $
                 (iv `at` 0) `xor` 0x01010000 `xor` (keylen `shiftL` 8) `xor` outlen
          , _t0 = 0 -- input count low word
          , _t1 = 0 -- input count high word
          , _c = 0  -- pointer within buffer
          , _outlen = fromIntegral outlen
          , _b = pack $ replicate 128 0 -- zero input block. in C code this starts at keylen, why??
          } &
          (\ctx -> if keylen > 0 then blake2b_update ctx key & (\c -> c { _c = 128}) else ctx)

slice c l bs = go (B.splitAt (if c >= l then l else l - c) bs) where
  go (x,y) | B.null y = [x]
           | otherwise = x:(go (B.splitAt l y))


blake2b_update :: Blake2BCtx -> ByteString -> Blake2BCtx
blake2b_update ctx bs = foldl update ctx (slice (_c ctx) 128 bs)
  where update cx s = resetMaybe cx & cpyBuf s
        resetMaybe cx
          | _c cx < 128 = cx
          | otherwise =
              let t0 = _t0 cx + 128
                  t1 = _t1 cx + (if t0 < 128 then 1 else 0)
              in (blake2b_compress (cx { _t0 = t0, _t1 = t1 }) False) { _c = 0 }
        cpyBuf s cx = cx {
          _b = B.take (_c cx) (_b cx) <> s,
          _c = B.length s + _c cx
          }


testM = mk (0x636261:replicate 15 0)

testC = let Right c = blake2b_init 32 mempty in c -- { _b = mk128B "abc" }

mk128B b = pack $ P.take 128 $ unpack b P.++ replicate 128 0

inB :: ByteString
inB = "akjsvhsjkdfhvjsakhfvjkdhsvnfklsjanvskdjvkdjsvfksdhnvkjdfavksnksjnfajvjklsnkjsfdajkldahvfadvndfjvalkhfnvkdfjsnvkljnkfkajsdnaskjskdjvfsfvkkdsadshfjkalsvaklsdhvnlksfjvnskdhnhjdnshsdfkvnfvads"

-- testCtx = Blake2BCtx testM

hex :: (Show a,Integral a,Functor f,Foldable f) => f a -> f String
hex = fmap (reverse . P.take 16 . (P.++ "0000000000000000") . reverse . (`showHex` ""))