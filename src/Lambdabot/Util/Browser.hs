{-# LANGUAGE PatternGuards #-}

-- | URL Utility Functions

module Lambdabot.Util.Browser
    ( urlPageTitle
    , browseLB
    ) where

import Codec.Binary.UTF8.String
import Control.Applicative
import Control.Monad.Trans
import Lambdabot.Monad
import Lambdabot.Util (limitStr)
import Network.Browser
import Network.HTTP
import Network.URI
import Text.HTML.TagSoup
import Text.HTML.TagSoup.Match

-- | Run a browser action with some standardized settings
browseLB :: MonadLB m => BrowserAction conn a -> m a
browseLB act = lb $ do
    proxy' <- getConfig proxy
    liftIO . browse $ do
        setOutHandler (const (return ()))
        setErrHandler (const (return ()))
        
        setAllowRedirects True
        setMaxRedirects (Just 5)
        setProxy proxy'
        act

-- | Limit the maximum title length to prevent jokers from spamming
-- the channel with specially crafted HTML pages.
maxTitleLength :: Int
maxTitleLength = 80

-- | Fetches a page title suitable for display.  Ideally, other
-- plugins should make use of this function if the result is to be
-- displayed in an IRC channel because it ensures that a consistent
-- look is used (and also lets the URL plugin effectively ignore
-- contextual URLs that might be generated by another instance of
-- lambdabot; the URL plugin matches on 'urlTitlePrompt').
urlPageTitle :: String -> BrowserAction (HandleStream String) (Maybe String)
urlPageTitle url = do
    title <- rawPageTitle url
    return $ fmap prettyTitle title
    where
      prettyTitle = limitStr maxTitleLength

-- | Fetches a page title for the specified URL.  This function should
-- only be used by other plugins if and only if the result is not to
-- be displayed in an IRC channel.  Instead, use 'urlPageTitle'.
rawPageTitle :: String -> BrowserAction (HandleStream String) (Maybe String)
rawPageTitle url = do
    (_, result) <- request (getRequest (takeWhile (/='#') url))
    case rspCode result of
        (2,0,0)   -> do
            case takeWhile (/= ';') <$> lookupHeader HdrContentType (rspHeaders result) of
                Just "text/html"       -> return $ extractTitle (rspBody result)
                Just "application/pdf" -> rawPageTitle (googleCacheURL url)
                _                      -> return $ Nothing
        _         -> return Nothing
    
    where googleCacheURL = (gURL++) . escapeURIString (const False)
          gURL = "http://www.google.com/search?hl=en&q=cache:"

-- | Given a server response (list of Strings), return the text in
-- between the title HTML element, only if it is text/html content.
-- Now supports all(?) HTML entities thanks to TagSoup.
extractTitle :: String -> Maybe String
extractTitle = content . tags . decodeString where
    tags = closing . opening . canonicalizeTags . parseTags
    opening = dropWhile (not . tagOpenLit "title" (const True))
    closing = takeWhile (not . tagCloseLit "title")

    content = maybeText . format . innerText
    format = unwords . words
    maybeText [] = Nothing
    maybeText t  = Just (encodeString t)
