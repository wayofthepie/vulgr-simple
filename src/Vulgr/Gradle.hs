{-# LANGUAGE DataKinds       #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeOperators   #-}
module Vulgr.Gradle where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson
import qualified Data.HashMap.Strict as M
import Data.Monoid
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Database.Neo4j as Neo
import qualified Database.Neo4j.Transactional.Cypher as TC

import Debug.Trace

data GradleDependencySpec = GradleDependencySpec
    { gDepName     :: T.Text
    , gDepDesc     :: Maybe T.Text
    , gDepConfigs  :: [Configuration]
    , gDepVersion  :: Maybe T.Text -- FIXME: SemVer?
    } deriving (Eq, Show)

instance FromJSON GradleDependencySpec where
    parseJSON (Object o) = GradleDependencySpec
        <$> o .: "name"
        <*> o .:? "description"
        <*> o .: "configurations"
        <*> o .:? "version"


data Configuration = Configuration
    { confName :: T.Text
    , confDesc :: Maybe T.Text
    , confDeps :: Maybe [Dependency]
--    , confModuleInsights :: Maybe [ModuleInsights] ignore for now
    } deriving (Eq, Show)

instance FromJSON Configuration where
    parseJSON (Object o) = Configuration
        <$> o .: "name"
        <*> o .:? "description"
        <*> o .:? "dependencies"

data Dependency = Dependency
    { depModule          :: Maybe T.Text
    , depName            :: T.Text
    , depResolvable      :: Bool
    , depHasConflict     :: Maybe Bool
    , depAlreadyRendered :: Bool
    , depChildren        :: Maybe [Dependency]
    } deriving (Eq, Show)

instance FromJSON Dependency where
    parseJSON (Object o) = Dependency
        <$> o .: "module"
        <*> o .: "name"
        <*> o .: "resolvable"
        <*> o .:? "hasConfict"
        <*> o .: "alreadyRendered"
        <*> o .: "children"

data Project = Project
    { projName :: T.Text
    } deriving (Eq, Show)


-- | Analyzes the gradle dependency spec and builds a graph of this projects
-- dependencies and transitive dependencies in each configuration.
--
-- TODO : Abstract to a type class for operation with different build tools like
-- maven etc...
--
-- TODO : Why do we care about the results here...? If we do care, it should
-- relate to a Configuration (compile, archive, etc..).
graphGradleDeps :: GradleDependencySpec -> IO (Either TC.TransError ())
graphGradleDeps gdeps = hardConn >>= \conn -> do
    n4jTransaction conn $ do
        -- Currently a node name is the project name and version combined. These should really
        -- be two properties
        let proj = Project (gDepName gdeps <> ":" <> (textOrUndefined $ gDepVersion gdeps))

        TC.cypher ("MERGE ( n:PROJECT { name : {name}} )") (project2map proj)
        mapM_ (\config -> createAndRelate proj (traceShow (confName config) $ confName config)
            (confDeps config)) $ gDepConfigs gdeps


-- | Create the top-level direct dependency nodes and relate them to the root node.
createAndRelate :: Project -> T.Text -> Maybe [Dependency] -> TC.Transaction ()
createAndRelate p relationName mdeps = case mdeps of
    Nothing   -> pure ()
    Just deps ->
        -- FIXME : Need to sanitize relation names correctly!
        let rName = T.replace "-" "" relationName
        in  mapM_ (relateProjectAndDep p rName) $ deps


-- Relate a project and its direct dependency.
relateProjectAndDep :: Project -> T.Text -> Dependency -> TC.Transaction ()
relateProjectAndDep p relationName d = do
    let pName = projName p
    let dName = depName d
    TC.cypher ("MERGE ( n:PROJECT { name : {name} } )") $
        M.fromList [
            (T.pack "name", TC.newparam dName)
        ]
    createRelationship pName pName dName relationName
    case depChildren d of
        Just deps -> graphTransitiveDeps pName relationName d deps >> pure ()
        Nothing   -> pure ()


-- | Graph the projects transitive dependencies.
--
-- Currently this works as follows:
--  1. The list of dependencies are the dependencies of the parent depencency
--     which is a direct dfependency of the given project in the given configuration.
--  2. We recursively relate dependencies with their children with an edge corresponding
--     to the gradle configuration (compile, runtime etc...).
--
-- graphTransitiveDeps projectName configName parentDep deps
--
graphTransitiveDeps :: T.Text -> T.Text -> Dependency -> [Dependency] -> TC.Transaction ()
graphTransitiveDeps projectName configName parent deps =
    graphTransitiveDeps' projectName configName parent deps

graphTransitiveDeps' :: T.Text -> T.Text -> Dependency -> [Dependency] -> TC.Transaction ()
graphTransitiveDeps' _ _ _ [] = return ()
graphTransitiveDeps' pname cname parent (dep:deps) = do
    TC.cypher ("MERGE ( n:PROJECT { name : {name} } )") (dep2map dep)
    createRelationship pname (depName parent) (depName dep) cname
    -- If this dependency has children graph them.
    case depChildren dep of
        Just tdeps -> graphTransitiveDeps' pname cname dep tdeps
        Nothing    -> pure ()

    graphTransitiveDeps' pname cname parent deps


-- Helpers
createRelationship :: T.Text -> T.Text -> T.Text -> T.Text -> TC.Transaction ()
createRelationship projectName from to relation = traceShow ("Creating rel for " <> projectName <> from <> " " <> relation <>" " <> to) $ do


    -- Create the relationship between the two nodes. Merge here ensures
    -- we don't overwrite an existing relationship.
    TC.cypher ("MATCH (a:PROJECT),(b:PROJECT)"
        <> "WHERE a.name = {from} AND b.name = {to}"
        <> "MERGE (a)-[r:DependsOn{project:{projectName}}]->(b)"
        <> "RETURN r") $ M.fromList [
                (T.pack "from", TC.newparam $ from)
                , (T.pack "to", TC.newparam $ to)
                , (T.pack "projectName", TC.newparam $ projectName)
                ]

    -- Add the relationship name to the properties of the relationship.
    -- This is an array of all the ways the parent depends on the child.
    TC.cypher ("MATCH (a:PROJECT)-[r:DependsOn]->(b:PROJECT)"
        <> "WHERE a.name = {from} AND b.name = {to}"
        <> "AND NOT ({relationName} in r.config) AND r.project = {projectName}"
        <> "SET r.config = coalesce(r.config,[]) + {relationName}"
        <> "RETURN r") $ M.fromList [
                (T.pack "from", TC.newparam $ from)
                , (T.pack "to", TC.newparam $ to)
                , (T.pack "relationName", TC.newparam $ relation)
                , (T.pack "projectName", TC.newparam $ projectName)
                ]
    pure ()



project2map project =
    let pName = projName project
    in  M.fromList [
            (T.pack "name", TC.newparam pName)
            ]

dep2map dep = project2map $ Project (depName dep)

textOrUndefined :: Maybe T.Text -> T.Text
textOrUndefined maybeTxt = case maybeTxt of
    Just txt -> txt
    Nothing  -> "undefined"


n4jTransaction :: Neo.Connection -> TC.Transaction a ->  IO (Either TC.TransError a)
n4jTransaction conn action = flip Neo.runNeo4j conn $
    TC.runTransaction action

-- Hardcode the connection details for now.
-- FIXME : This should be picked up from external configuration.
hardConn = (Neo.newAuthConnection (TE.encodeUtf8 "172.17.0.3") 7474 (TE.encodeUtf8 "neo4j", TE.encodeUtf8 "test"))
