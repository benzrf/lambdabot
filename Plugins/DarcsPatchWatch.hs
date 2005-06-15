--
-- Copyright (c) 2005 Stefan Wehr (http://www.stefanwehr.de)
-- GPL version 2 or later (see http://www.gnu.org/copyleft/gpl.html)
--

--
-- | Watch darcs patches arriving...
--
module Plugins.DarcsPatchWatch (theModule) where

import Prelude hiding ( catch )
import List ( intersperse, delete )
import Control.Concurrent
import Control.Exception
import Control.Monad.Trans ( liftIO, MonadIO )
import System.Directory
import System.Time

import Lambdabot
import Util
import PosixCompat ( popen )

newtype DarcsPatchWatch = DarcsPatchWatch ()

theModule :: MODULE
theModule = MODULE $ DarcsPatchWatch ()


--
-- Configuration variables
--

announceTarget :: String
announceTarget = "#00maja"

inventoryFile :: String
inventoryFile = "_darcs/inventory"

sleepSeconds :: Int
sleepSeconds = 10

darcsCmd :: String
darcsCmd = "darcs"

--
-- The repository data type
--

type Repos = [Repo]

data Repo = Repo { repo_location     :: FilePath
                 , repo_lastAnnounced :: Maybe CalendarTime
                 , repo_nlinesAtLastAnnouncement :: Int }
            deriving (Eq,Ord,Show,Read)

showRepo :: Repo -> String
showRepo repo = 
    "{Repository " ++ show (repo_location repo) ++ ", last announcement: " ++
    (case repo_lastAnnounced repo of
       Nothing -> "unknown"
       Just ct -> formatTime ct) ++ "}"

showRepos :: Repos -> String
showRepos [] = "{no repositories defined}"
showRepos l = '{' : ((concat . intersperse ", " . map showRepo) l ++ "}")


--
-- The state of the plugin
--

data DarcsPatchWatchState = DarcsPatchWatchState
                          { dpw_threadId  :: Maybe ThreadId
                          , dpw_repos     :: Repos }

stateSerializer :: Serializer DarcsPatchWatchState
stateSerializer = 
    Serializer { serialize = Just . ser
               , deSerialize = deSer }
    where ser (DarcsPatchWatchState _ repos) = show repos
          deSer s = 
              do repos <- readM s
                 return $ (DarcsPatchWatchState 
                           { dpw_threadId = Nothing
                           , dpw_repos = repos })

getRepos :: (MonadIO m, ?name::String, ?ref::MVar DarcsPatchWatchState) => 
            m Repos
getRepos = 
    do s <- readMS
       return (dpw_repos s)

setRepos :: (?name::String, ?ref::MVar DarcsPatchWatchState) => Repos -> LB ()
setRepos repos = 
    do modifyMS (\s -> s { dpw_repos = repos })


--
-- The plugin itself
--

instance Module DarcsPatchWatch DarcsPatchWatchState where
    moduleHelp    _ s = return $ case s of
        "repos"        -> "@repos, list all registered darcs repositories"
        "repo-add"    -> "@repos-add path, add a repository"
        "repo-del" -> "@repos-del path, delete a repository" 
        _ -> "Watch darcs repositories. Provides @repos, @repo-add, @repo-del"

    moduleCmds  _ = return ["repos", "repo-add", "repo-del"] 

    moduleDefState  _ = return (DarcsPatchWatchState Nothing [])
    moduleSerialize _ = Just stateSerializer

    moduleInit      _ = do
      tid <- lbIO (\conv -> let ?ref = ?ref in forkIO $ watchRepos conv)
      modifyMS (\s -> s { dpw_threadId = Just tid })
    moduleExit      _ = 
        do s <- readMS
           case dpw_threadId s of
             Nothing -> return ()
             Just tid ->
                 liftIO $ killThread tid

    process _ _ source cmd rest =
           case cmd of
             "repos"       -> printRepos source rest
             "repo-add"    -> addRepo source rest
             "repo-del"    -> delRepo source rest
             _ -> error "unimplemented command"

--
-- Configuration commands
--

printRepos :: String -> String -> ModuleT DarcsPatchWatchState IRC ()
printRepos source "" = 
    do repos <- getRepos
       ircPrivmsg source (showRepos repos)
printRepos _ _ =
    error "@todo given arguments, try @todo-add or @listcommands todo"

addRepo :: String -> String -> ModuleT DarcsPatchWatchState IRC ()
addRepo source rest | null (dropSpace rest) = 
    ircPrivmsg source "argument required"
addRepo source rest = 
    do x <- mkRepo rest
       case x of
         Left s -> send ("cannot add invalid repository: " ++ s)
         Right r -> do repos <- getRepos
                       if r `elem` repos
                          then send ("cannot add already existing repository " 
                                     ++ showRepo r)
                          else
                          do setRepos (r:repos)
                             send ("repository " ++ showRepo r ++ " added")
    where send = ircPrivmsg source

delRepo :: String -> String -> ModuleT DarcsPatchWatchState IRC ()
delRepo source rest | null (dropSpace rest) = 
    ircPrivmsg source "argument required"
delRepo source rest = 
    do x <- mkRepo rest
       case x of
         Left s -> ircPrivmsg source ("cannot delete invalid repository: " ++ s)
         Right r -> do repos <- getRepos
                       if not (r `elem` repos)
                          then send ("cannot delete non-existing repository " 
                                     ++ showRepo r)
                          else 
                          do setRepos (delete r repos)
                             send ("repository " ++ showRepo r ++ " deleted")
    where send = ircPrivmsg source                     

mkRepo :: String -> ModuleT DarcsPatchWatchState IRC (Either String Repo)
mkRepo pref' =
    do x <- liftIO $ do let path = mkInventoryPath pref'
                            pref = dropSpace pref'
                        perms <- getPermissions path
                        return (Right (pref, perms))
                     `catch` (\e -> return $ Left (show e))
       case x of
         Left e -> return $ Left e
         Right (pref, perms) 
             | readable perms -> return $ Right $ Repo pref Nothing 0
             | otherwise -> 
                 return $ Left ("repository's inventory file not readable")


--
-- The heart of the plugin: watching darcs repositories
--

watchRepos ::  (?name::String, ?ref::MVar DarcsPatchWatchState) => 
               (forall a. LB a -> IO a) -> IO ()
watchRepos conv =
    do repos <- getRepos
       debug ("checking darcs repositories " ++ showRepos repos)
       repos' <- mapM (checkRepo conv) repos
       conv $ setRepos repos'
       threadDelay sleepTime
       watchRepos conv
    where sleepTime :: Int  -- in milliseconds
          sleepTime = sleepSeconds * 1000 * 1000  -- don't change, change sleepSeconds



checkRepo :: (?name::String, ?ref::MVar DarcsPatchWatchState) => 
             (forall a. LB a -> IO a) -> Repo -> IO Repo
checkRepo conv repo = 
    do mtime <- getModificationTime (repo_location repo)
       case repo_lastAnnounced repo of
         Nothing                           -> announceRepoChanges conv repo
         Just ct | toClockTime ct <= mtime -> announceRepoChanges conv repo
                 | otherwise               -> return repo

announceRepoChanges :: (?name::String, ?ref::MVar DarcsPatchWatchState) => 
                       (forall a. LB a -> IO a) -> Repo -> IO Repo
announceRepoChanges conv r = 
    do let header = "Changes have been made to " ++ repo_location r
       now <- getClockTime
       (output, errput) <- runDarcs (repo_location r)
       nlines <- 
           if not (null errput)
              then do send (header ++ "\ndarcs failed: " ++ errput)
                      return (repo_nlinesAtLastAnnouncement r)
              else let olines = lines output
                       lastN = repo_nlinesAtLastAnnouncement r
                       new = take (length olines - lastN) olines
                   in do if null new
                            then debug ("silently ignoring that darcs hasn't " ++
                                        "produced any new lines since last check")
                            else send (header ++ "\n" ++ unlines new)
                         return (length olines)
       ct <- toCalendarTime now
       return $ r { repo_nlinesAtLastAnnouncement = nlines
                  , repo_lastAnnounced = Just ct }
    where send s = conv $ ircPrivmsg announceTarget s

runDarcs :: FilePath -> IO (String, String)
runDarcs loc =
    do (output, errput, _) <- popen darcsCmd ["changes", "--repo=" ++ loc]
                                Nothing
       if not (null errput)
          then debug errput
          else return ()
       return (output, errput)


--
-- Helpers
--

mkInventoryPath :: String -> FilePath
mkInventoryPath prefix = 
    let pref = dropSpace prefix
        in joinPath pref inventoryFile

joinPath :: FilePath -> FilePath -> FilePath
joinPath p q =
    case reverse p of
      '/':_ -> p ++ q
      []    -> q
      _     -> p ++ "/" ++ q

debug :: String -> IO ()
debug s = putStrLn ("[DarcsPatchWatch] " ++ s)

formatTime :: CalendarTime -> String
formatTime = calendarTimeToString