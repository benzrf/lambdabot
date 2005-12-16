--
-- | Persistent state
--
module Plugins.Paste (theModule) where

import Lambdabot
import LBState
import Control.Concurrent
import Control.Monad.Trans (liftIO)

newtype PasteModule = PasteModule ()

theModule :: MODULE
theModule = MODULE $ PasteModule ()

announceTarget :: String
announceTarget = "#haskell"

instance Module PasteModule ThreadId where
    moduleCmds      _ = []
    moduleInit      _ = do
      tid <- lbIO (\conv -> 
        forkIO $ pasteListener $ conv . ircPrivmsg announceTarget)
      writeMS tid
    moduleExit      _ = liftIO . killThread =<< readMS
    process _ _ _ _ _ = return ()


-- | Implements a server that listens for pastes from a paste script.
--   Authentification is done via...
pasteListener :: (String -> IO ()) -> IO ()
pasteListener say = do
  -- ...
  say "someone has pasted something somewhere"
  -- ...
