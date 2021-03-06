{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ScopedTypeVariables #-}

module CmmLive
    ( CmmLocalLive
    , cmmLocalLiveness
    , cmmGlobalLiveness
    , liveLattice
    , gen_kill
    )
where

import DynFlags
import BlockId
import Cmm
import PprCmmExpr ()
import Hoopl.Dataflow

import Maybes
import Outputable

-----------------------------------------------------------------------------
-- Calculating what variables are live on entry to a basic block
-----------------------------------------------------------------------------

-- | The variables live on entry to a block
type CmmLive r = RegSet r
type CmmLocalLive = CmmLive LocalReg

-- | The dataflow lattice
liveLattice :: Ord r => DataflowLattice (CmmLive r)
{-# SPECIALIZE liveLattice :: DataflowLattice (CmmLive LocalReg) #-}
{-# SPECIALIZE liveLattice :: DataflowLattice (CmmLive GlobalReg) #-}
liveLattice = DataflowLattice emptyRegSet add
  where
    add (OldFact old) (NewFact new) =
        let !join = plusRegSet old new
        in changedIf (sizeRegSet join > sizeRegSet old) join


-- | A mapping from block labels to the variables live on entry
type BlockEntryLiveness r = BlockEnv (CmmLive r)

-----------------------------------------------------------------------------
-- | Calculated liveness info for a CmmGraph
-----------------------------------------------------------------------------

cmmLocalLiveness :: DynFlags -> CmmGraph -> BlockEntryLiveness LocalReg
cmmLocalLiveness dflags graph =
  check $ dataflowAnalBwd graph [] liveLattice (xferLive dflags)
  where entry = g_entry graph
        check facts = noLiveOnEntry entry
                        (expectJust "check" $ mapLookup entry facts) facts

cmmGlobalLiveness :: DynFlags -> CmmGraph -> BlockEntryLiveness GlobalReg
cmmGlobalLiveness dflags graph =
  dataflowAnalBwd graph [] liveLattice (xferLive dflags)

-- | On entry to the procedure, there had better not be any LocalReg's live-in.
noLiveOnEntry :: BlockId -> CmmLive LocalReg -> a -> a
noLiveOnEntry bid in_fact x =
  if nullRegSet in_fact then x
  else pprPanic "LocalReg's live-in to graph" (ppr bid <+> ppr in_fact)

-- | The transfer equations use the traditional 'gen' and 'kill'
-- notations, which should be familiar from the Dragon Book.
gen  :: UserOfRegs r a => DynFlags -> a -> RegSet r -> RegSet r
{-# INLINE gen #-}
gen dflags a live = foldRegsUsed dflags extendRegSet live a

kill :: DefinerOfRegs r a => DynFlags -> a -> RegSet r -> RegSet r
{-# INLINE kill #-}
kill dflags a live = foldRegsDefd dflags deleteFromRegSet live a

gen_kill :: (DefinerOfRegs r a, UserOfRegs r a)
          => DynFlags -> a -> CmmLive r -> CmmLive r
{-# INLINE gen_kill #-}
gen_kill dflags a = gen dflags a . kill dflags a

-- | The transfer function
xferLive :: forall r . ( UserOfRegs    r (CmmNode O O)
                       , DefinerOfRegs r (CmmNode O O)
                       , UserOfRegs    r (CmmNode O C)
                       , DefinerOfRegs r (CmmNode O C))
         => DynFlags -> BwdTransfer CmmNode (CmmLive r)
{-# SPECIALIZE xferLive :: DynFlags -> BwdTransfer CmmNode (CmmLive LocalReg) #-}
{-# SPECIALIZE xferLive :: DynFlags -> BwdTransfer CmmNode (CmmLive GlobalReg) #-}
xferLive dflags = mkBTransfer3 fst mid lst
  where fst _ f = f
        mid :: CmmNode O O -> CmmLive r -> CmmLive r
        mid n f = gen_kill dflags n f
        lst :: CmmNode O C -> FactBase (CmmLive r) -> CmmLive r
        lst n f = gen_kill dflags n $ joinOutFacts liveLattice n f
