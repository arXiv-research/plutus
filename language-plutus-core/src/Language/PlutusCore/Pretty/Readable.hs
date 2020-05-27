-- | A "readable" Agda-like way to pretty-print PLC entities.

{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds       #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies    #-}

module Language.PlutusCore.Pretty.Readable
    ( module Export
    , module Language.PlutusCore.Pretty.Readable
    ) where

import           PlutusPrelude

import           Language.PlutusCore.Pretty.ConfigName

import           Control.Lens
import           Text.PrettyBy.Fixity                  as Export

data ShowKinds
    = ShowKindsYes
    | ShowKindsNo
    deriving (Show, Eq)

-- | Configuration for the readable pretty-printing.
data PrettyConfigReadable configName = PrettyConfigReadable
    { _pcrConfigName    :: configName
    , _pcrRenderContext :: RenderContext
    , _pcrShowKinds     :: ShowKinds
    }

type instance HasPrettyDefaults (PrettyConfigReadable _) = 'True

-- | The "readably pretty-printable" constraint.
type PrettyReadableBy configName = PrettyBy (PrettyConfigReadable configName)

type PrettyReadable = PrettyReadableBy PrettyConfigName

type HasPrettyConfigReadable env configName =
    HasPrettyConfig env (PrettyConfigReadable configName)

makeLenses ''PrettyConfigReadable

instance configName ~ PrettyConfigName => HasPrettyConfigName (PrettyConfigReadable configName) where
    toPrettyConfigName = _pcrConfigName

instance HasRenderContext (PrettyConfigReadable configName) where
    renderContext = pcrRenderContext

-- | The fixity of a binder.
binderFixity :: Fixity
binderFixity = Fixity RightAssociative 1

-- | The fixity of @(->)@.
arrowFixity :: Fixity
arrowFixity = Fixity RightAssociative 2

-- | A 'PrettyConfigReadable' with the fixity specified to 'botFixity'.
botPrettyConfigReadable :: configName -> ShowKinds -> PrettyConfigReadable configName
botPrettyConfigReadable configName = PrettyConfigReadable configName botRenderContext

-- | A 'PrettyConfigReadable' with the fixity specified to 'topFixity'.
topPrettyConfigReadable :: configName -> ShowKinds -> PrettyConfigReadable configName
topPrettyConfigReadable configName = PrettyConfigReadable configName topRenderContext
