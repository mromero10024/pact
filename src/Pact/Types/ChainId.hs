{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DerivingStrategies #-}
-- |
-- Module      :  Pact.Types.Runtime
-- Copyright   :  (C) 2019 Stuart Popejoy
-- License     :  BSD-style (see the file LICENSE)
-- Maintainer  :  Stuart Popejoy <stuart@kadena.io>,
--                Emily Pillmore <emily@kadena.io>
--
-- ChainId data and its associated combinators
--
module Pact.Types.ChainId
( -- * types
  ChainId(..)
  -- * optics
, chainId
, _ChainId
) where

import GHC.Generics

import Control.DeepSeq
import Control.Lens

import Data.Aeson (ToJSON, FromJSON)
import Data.Serialize (Serialize)
import Data.String (IsString)
import Data.Text

import Pact.Types.Term (ToTerm(..))

-- | Expresses unique platform-specific chain identifier.
--
newtype ChainId = ChainId { _chainId :: Text }
  deriving (Eq, Show, Generic, IsString, ToJSON, FromJSON, Serialize)
  deriving newtype (NFData)

instance ToTerm ChainId where toTerm (ChainId i) = toTerm i

instance Wrapped ChainId

-- | Chain Id getter and setter which is a strict get/set pair
--
chainId :: Lens' ChainId Text
chainId = lens _chainId (\_ t -> ChainId t)

-- | Convenience isomorphism 'ChainId' <-> 'Text'
--
_ChainId :: Iso' ChainId Text
_ChainId = iso _chainId ChainId
