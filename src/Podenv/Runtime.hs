{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | This module contains the podman/bubblewrap context wrapper
module Podenv.Runtime
  ( createLocalhostRunEnv,
    showRuntimeCmd,
    getPodmanPodStatus,
    deletePodmanPod,

    -- * Podman helpers
    podman,
    podmanRunArgs,

    -- * Bubblewrap helpers
    bwrap,
    bwrapRunArgs,

    -- * data type and lenses
    RuntimeEnv (..),
    RunMode (..),
    module Podenv.Context,
    GlobalEnv (..),
    defaultGlobalEnv,
    RuntimeBackend (..),
  )
where

import Data.Map.Strict qualified as Map
import Data.Set qualified
import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import Podenv.Capability qualified
import Podenv.Config (Config, defaultSystemConfig, select)
import Podenv.Context
import Podenv.Dhall hiding (command, environ, name, namespace, network)
import Podenv.Dhall qualified as Podenv
import Podenv.Env
import Podenv.Image
import Podenv.Prelude
import System.Directory (doesDirectoryExist, renameFile)
import System.Exit (ExitCode (ExitSuccess))
import System.Posix.Files qualified
import System.Process.Typed qualified as P

data RuntimeEnv = RuntimeEnv
  { buildInfo :: Text,
    buildRuntime :: ContextEnvT (),
    updateRuntime :: ContextEnvT (),
    appToContext :: Podenv.Capability.Mode -> IO Context,
    execute :: RunMode -> Context -> ContextEnvT (),
    runtimeBackend :: RuntimeBackend
  }

data RuntimeBackend
  = Podman ImageName
  | Bubblewrap FilePath

data RunMode = Foreground | Background deriving (Eq, Show)

ensureResolvConf :: FilePath -> IO (Context -> Context)
ensureResolvConf fp
  -- When using host rootfs, then we need to mount /etc/resolv.conf target when it is a symlink
  | fp == "/" = do
    symlink <- System.Posix.Files.isSymbolicLink <$> System.Posix.Files.getSymbolicLinkStatus "/etc/resolv.conf"
    if symlink
      then do
        realResolvConf <- getSymlinkPath
        pure $ addMount realResolvConf (roHostPath realResolvConf)
      else pure id
  -- Otherwise we can just mount it directly
  | otherwise = pure $ addMount "/etc/resolv.conf" (roHostPath "/etc/resolv.conf")
  where
    getSymlinkPath = do
      realResolvConf <- System.Posix.Files.readSymbolicLink "/etc/resolv.conf"
      pure $
        if "../" `isPrefixOf` realResolvConf
          then drop 2 realResolvConf
          else realResolvConf

createLocalhostRunEnv :: AppEnv -> Application -> Name -> RuntimeEnv
createLocalhostRunEnv appEnv app ctxName = RuntimeEnv {..}
  where
    appToContext amode = do
      setResolv <- case runtimeBackend of
        Bubblewrap fp -> ensureResolvConf fp
        _ -> pure id
      let validate ctx = case runtimeBackend of
            Bubblewrap _ | null (ctx ^. command) -> ctx & command .~ ["/bin/sh"]
            _ -> ctx
      ctx <- runAppEnv appEnv $ Podenv.Capability.prepare amode app ctxName
      pure $ ctx & setResolv . validate
    runtimeBackend = case app ^. appRuntime of
      Image x -> Podman $ ImageName x
      Rootfs root -> Bubblewrap $ toString root
      Container cb -> Podman . mkImageName $ cb
      Nix _ -> Bubblewrap "/"

    (buildInfo, (buildRuntime, updateRuntime)) = case app ^. appRuntime of
      Podenv.Image iname -> ("image:" <> iname, noBuilder)
      Podenv.Rootfs fp -> ("rootfs:" <> fp, noBuilder)
      Podenv.Container cb -> manageContainer cb
      Podenv.Nix expr -> ("nix:" <> show expr, (prepareNix expr, error "Nix update is not implemented"))
      where
        noBuilder = (pure (), pure ())

    execute :: RunMode -> Context -> ContextEnvT ()
    execute rm ctx = do
      re <- ask
      traverse_ (liftIO . ensureHostDirectory (volumesDir re)) (Map.elems $ ctx ^. mounts)
      case runtimeBackend of
        Podman image -> executePodman rm ctx image
        Bubblewrap fp -> executeBubblewrap ctx fp

    manageContainer cb = ("# Containerfile " <> imageName, (buildContainer, updateContainer))
      where
        buildContainer = do
          imageReady <- liftIO $ checkImageExist imageName
          unless imageReady $ do
            debug $ "Building image: " <> imageName
            liftIO $ buildImage imageName fileName fileContent (cb ^. cbImage_volumes)

        updateContainer = case cb ^. cbImage_update of
          Nothing -> error "The container is missing the `image_update` attribute"
          Just cmd -> liftIO do
            buildImage
              imageName
              (fileName <> "-update")
              (unlines ["FROM " <> imageName, "RUN " <> cmd])
              (cb ^. cbImage_volumes)

        fileContent = cb ^. cbContainerfile
        ImageName imageName = mkImageName cb
        fileName = "Containerfile_" <> toString (imageNameToFP imageName)
          where
            imageNameToFP = Text.replace "/" "_" . Text.replace ":" "-"

    prepareNix :: Flakes -> ContextEnvT ()
    prepareNix flakes = do
      built <- checkIfBuilt fileName (show $ nixArgs flakes)
      unless built $ do
        ensureNixInstalled
        ctx <- liftIO buildCtx
        execute Foreground ctx
        liftIO do
          cacheDir <- getCacheDir
          Text.writeFile (cacheDir </> fileName) (show $ nixArgs flakes)
      where
        fileName = toString $ "nix_" <> unName ctxName

        -- The location where we expect to find the `nix` command
        nixStore re = Podenv.Runtime.volumesDir re </> "nix-store"
        ensureNixInstalled = do
          re <- ask
          let store = nixStore re
          debug $ toText $ "Checking if " <> store </> nixCommandProfile <> " exists"
          nixInstalled <- liftIO $ doesSymlinkExist $ store </> nixCommandProfile
          unless nixInstalled $ do
            debug $ toText $ "Checking if " <> store </> "store" <> " exists"
            storeExist <- liftIO $ doesDirectoryExist $ store </> "store"
            when storeExist $ error $ "existing nix-store is invalid, try removing " <> toText (nixStore re)

            let cfg = fromMaybe (error "Need config") $ config re
                nixSetupApp = case Podenv.Config.select cfg ["nix.setup"] of
                  Left e -> error e
                  Right (_, setupApp) -> setupApp
                mode = Podenv.Capability.Regular []
            debug "[+] Installing nix-store with nix.setup"
            ctx <- liftIO $ runAppEnv appEnv $ Podenv.Capability.prepare mode nixSetupApp (Name "nix.setup")
            execute Foreground ctx

        builderName = Name $ "nix-builder-" <> unName ctxName
        buildCtx = runAppEnv appEnv do
          let ctx = Podenv.Context.defaultContext builderName
          setNix <- Podenv.Capability.setNix
          pure $ ctx & setNix . (Podenv.Context.network .~ True)

-- | Build a container image
buildImage :: Text -> FilePath -> Text -> [Text] -> IO ()
buildImage imageName fileName containerfile volumes = do
  hostUid <- getRealUserID
  cacheDir <- getCacheDir
  createDirectoryIfMissing True cacheDir
  let want = fileName <> ".want"
      wantfp = cacheDir </> want
  Text.writeFile wantfp containerfile
  -- podman build does not support regular volume, lets ensure absolute path
  volumesArgs <- traverse (mkVolumeArg cacheDir) volumes
  let buildArgs =
        ["build"]
          <> ["-t", toString imageName]
          <> ["--build-arg", "USER_UID=" <> show hostUid]
          <> map toString volumesArgs
          <> ["-f", want, cacheDir]
      cmd = Podenv.Runtime.podman buildArgs
  -- putTextLn $ "Building " <> imageName <> " with " <> toText want <> ": " <> show cmd
  P.runProcess_ cmd
  -- save that the build succeeded
  renameFile wantfp (cacheDir </> fileName)
  where
    mkVolumeArg :: FilePath -> Text -> IO Text
    mkVolumeArg cacheDir volume = do
      createDirectoryIfMissing True hostPath
      pure $ "-v=" <> toText hostPath <> ":" <> containerPath <> ":Z"
      where
        (p1, p2) = Text.break (== ':') volume
        hostPath = cacheDir </> toString p1
        containerPath = Text.drop 1 p2

checkImageExist :: Text -> IO Bool
checkImageExist imageName = do
  res <- P.runProcess (Podenv.Runtime.podman ["image", "exists", Text.unpack imageName])
  pure $ res == ExitSuccess

checkIfBuilt :: MonadIO m => FilePath -> Text -> m Bool
checkIfBuilt filename expected = liftIO do
  cacheDir <- getCacheDir
  current <- readFileM (cacheDir </> filename)
  pure $ current == expected

-- | Create host directory and set SELinux label if needed
ensureHostDirectory :: FilePath -> Volume -> IO ()
ensureHostDirectory volumesDir (MkVolume _ (Volume volumeName)) =
  ensureHostDirectory' $ volumesDir </> toString volumeName
ensureHostDirectory _ (MkVolume _ (HostPath fp)) | (last <$> nonEmpty fp) == Just '/' = ensureHostDirectory' fp
ensureHostDirectory _ _ = pure ()

ensureHostDirectory' :: FilePath -> IO ()
ensureHostDirectory' fp = do
  exist <- doesPathExist fp
  unless exist $ do
    createDirectoryIfMissing True fp
    P.runProcess_ $ P.proc "/bin/chcon" ["system_u:object_r:container_file_t:s0", fp]

executeBubblewrap :: Context -> FilePath -> ContextEnvT ()
executeBubblewrap ctx fp = do
  re <- ask
  let args = bwrapRunArgs re ctx fp
  let cmd = bwrap args
  debug $ show cmd
  P.runProcess_ cmd

bwrap :: [String] -> P.ProcessConfig () () ()
bwrap = P.setDelegateCtlc True . P.proc "bwrap"

commonArgs :: Context -> [Text]
commonArgs Context {..} =
  concatMap (\c -> ["--cap-add", show c]) $ sort $ Data.Set.toList _syscaps

bwrapRunArgs :: GlobalEnv -> Context -> FilePath -> [String]
bwrapRunArgs GlobalEnv {..} ctx@Context {..} fp = toString <$> args
  where
    userArg = case ctx ^. runAs of
      Just RunAsRoot -> ["--unshare-user", "--uid", "0"]
      Just RunAsHostUID -> []
      Just RunAsAnyUID -> ["--unshare-user", "--uid", show $ ctx ^. anyUid]
      Nothing -> []

    networkArg
      | _network = case _namespace of
        Just "host" -> []
        Just _ns -> error "Shared netns not implemented"
        Nothing -> [] -- TODO: implement private network namespace
      | otherwise = ["--unshare-net"]

    volumeArg :: (FilePath, Volume) -> [Text]
    volumeArg (destPath, MkVolume mode vtype) = case vtype of
      HostPath hostPath -> [volumeMode mode, toText hostPath, toText destPath]
      Volume x -> [volumeMode mode, toText $ volumesDir </> toString x, toText destPath]
      TmpFS -> ["--tmpfs", toText destPath]
      where
        volumeMode = \case
          RO -> "--ro-bind"
          RW -> "--bind"

    rootMounts = case fp of
      "/" ->
        doBind "usr"
          <> doBind "lib"
          <> doBind "lib64"
          <> doBind "bin"
          <> doBind "sbin"
          <> doBind "etc"
      c : _ | c `notElem` ['/', ':'] -> toText <$> [bindMode, toString volumesDir </> fp, "/"]
      _ -> doBind ""

    sysMounts
      | Data.Set.null _devices = []
      | otherwise = ["--ro-bind", "/sys", "/sys"]

    bindMode
      | ctx ^. ro = "--ro-bind"
      | otherwise = "--bind"
    doBind p = toText <$> [bindMode, fp </> p, "/" </> p]
    args =
      userArg
        <> ["--die-with-parent", "--unshare-pid", "--unshare-ipc", "--unshare-uts"]
        <> networkArg
        <> commonArgs ctx
        <> rootMounts
        <> ["--proc", "/proc"]
        <> ["--dev", "/dev"]
        <> ["--perms", "01777", "--tmpfs", "/tmp"]
        <> concatMap volumeArg (Map.toAscList _mounts)
        <> concatMap (\d -> ["--dev-bind", toText d, toText d]) _devices
        <> sysMounts
        <> ["--clearenv"]
        <> concatMap (\(k, v) -> ["--setenv", toText k, v]) (Map.toAscList _environ)
        <> cond (not _terminal) ["--new-session"]
        <> maybe [] (\wd -> ["--chdir", toText wd]) _workdir
        <> _command

showRuntimeCmd :: GlobalEnv -> RunMode -> Context -> RuntimeBackend -> Text
showRuntimeCmd re rm ctx = \case
  Podman image -> show . P.proc "podman" $ podmanRunArgs re rm ctx image
  Bubblewrap fp -> show . P.proc "bwrap" $ bwrapRunArgs re ctx fp

data GlobalEnv = GlobalEnv
  { verbose :: Bool,
    system :: SystemConfig,
    config :: Maybe Config,
    -- | The host location of the volumes directory, default to ~/.local/share/podenv/volumes
    volumesDir :: FilePath
  }

defaultGlobalEnv :: FilePath -> GlobalEnv
defaultGlobalEnv = GlobalEnv True defaultSystemConfig Nothing

type ContextEnvT a = ReaderT GlobalEnv IO a

debug :: Text -> ContextEnvT ()
debug msg = do
  isVerbose <- asks verbose
  when isVerbose $ liftIO $ hPutStrLn stderr ("[+] " <> toString msg)

cond :: Bool -> [a] -> [a]
cond b xs = if b then xs else []

infraName :: Text -> Text
infraName ns = ns <> "-ns"

podmanArgs :: Context -> [Text]
podmanArgs Context {..} = cond _interactive ["-i", "--detach-keys", ""] <> cond _terminal ["-t"]

podmanRunArgs :: GlobalEnv -> RunMode -> Context -> ImageName -> [String]
podmanRunArgs GlobalEnv {..} rmode ctx@Context {..} image = toString <$> args
  where
    portArgs = concatMap publishArg _ports
    publishArg port = ["--publish", showPort port]
    showPort port = show $ case port of
      -- podman does not seem to distinguish protocol
      PortTcp p -> p
      PortUdp p -> p

    hostnameArg = ["--hostname", unName _name]
    networkArg
      | _network =
        hostnameArg <> case _namespace of
          Just "host" -> ["--network", "host"]
          Just ns -> ["--network", "container:" <> infraName ns]
          Nothing -> maybe [] (\dns -> ["--dns=" <> dns]) (system ^. sysDns) <> portArgs
      | otherwise = ["--network", "none"]

    volumeArg :: (FilePath, Volume) -> [Text]
    volumeArg (fp, MkVolume mode vtype) = case vtype of
      HostPath x -> volume (toText x)
      Volume x -> volume (toText $ volumesDir </> toString x)
      TmpFS -> ["--mount", "type=tmpfs,destination=" <> toText fp]
      where
        volume hp = ["--volume", hp <> ":" <> toText fp <> showVolumeMode mode]
        showVolumeMode = \case
          RO -> ":ro"
          RW -> ""

    -- The goal here is to ensure host files created by the container are readable by the host user.
    userArg = case ctx ^. runAs of
      Just RunAsRoot -> ["--user", "0"]
      Just RunAsHostUID -> ["--user", show (ctx ^. uid), "--userns", "keep-id"]
      Just RunAsAnyUID ->
        let x = ctx ^. anyUid
         in ["--user", show x, "--uidmap", show x <> ":0:1", "--uidmap", "0:1:" <> show x]
      Nothing -> []

    nameArg = ["--name", unName _name]

    args =
      ["run"]
        <> podmanArgs ctx
        <> ["--detach" | rmode == Background]
        <> maybe [] (\h -> ["--hostname", h]) _hostname
        <> cond _privileged ["--privileged"]
        <> ["--rm"]
        <> cond _ro ["--read-only=true"]
        <> cond (not _selinux) ["--security-opt", "label=disable"]
        <> userArg
        <> networkArg
        <> commonArgs ctx
        <> concatMap (\d -> ["--device", toText d]) _devices
        <> maybe [] (\wd -> ["--workdir", toText wd]) _workdir
        <> concatMap (\(k, v) -> ["--env", toText $ k <> "=" <> v]) (Map.toAscList _environ)
        <> concatMap volumeArg (Map.toAscList _mounts)
        <> nameArg
        <> [unImageName image]
        <> _command

podman :: [String] -> P.ProcessConfig () () ()
podman = P.setDelegateCtlc True . P.proc "podman"

data PodmanStatus
  = -- | The container does not exists, it needs to be created
    NotFound
  | -- | The container is already running
    Running
  | -- | The container ran and it is now stopped
    Unknown Text
  deriving (Show, Eq)

getPodmanPodStatus :: MonadIO m => Name -> m PodmanStatus
getPodmanPodStatus (Name cname) = do
  (_, stdout', _) <- P.readProcess (podman ["inspect", Text.unpack cname, "--format", "{{.State.Status}}"])
  pure $ case stdout' of
    "" -> NotFound
    "running\n" -> Running
    other -> Unknown (Text.dropWhileEnd (== '\n') $ decodeUtf8 other)

deletePodmanPod :: MonadIO m => Name -> m ()
deletePodmanPod (Name cname) =
  P.runProcess_ (podman ["rm", toString cname])

ensureInfraNet :: Text -> ContextEnvT ()
ensureInfraNet ns = do
  debug $ "Ensuring infra net for: " <> show ns
  let pod = infraName ns
  infraStatus <- getPodmanPodStatus (Name pod)
  case infraStatus of
    Running -> pure ()
    _ -> do
      when (infraStatus /= NotFound) $
        -- Try to delete any left-over infra container
        P.runProcess_ (podman ["rm", toString pod])

      system' <- asks system
      let cmd =
            podman $
              map toString $
                ["run", "--rm", "--name", pod]
                  <> ["--detach"]
                  <> maybe [] (\dns -> ["--dns=" <> dns]) (system' ^. sysDns)
                  <> ["ubi8"]
                  <> ["sleep", "infinity"]
      debug $ show cmd
      P.runProcess_ cmd

executePodman :: RunMode -> Context -> ImageName -> ContextEnvT ()
executePodman rm ctx image = do
  re <- ask
  case (ctx ^. namespace, ctx ^. network) of
    (Just ns, True) | ns /= mempty -> ensureInfraNet ns
    _ -> pure ()

  status <- getPodmanPodStatus (ctx ^. name)
  debug $ "Podman status of " <> cname <> ": " <> show status
  let cfail err = liftIO . mayFail . Left $ cname <> ": " <> err
  args <-
    case status of
      NotFound -> pure $ podmanRunArgs re rm ctx image
      Running -> cfail "container is already running, use `exec` to join, or `--name new` to start a new instance"
      Unknown _ -> recreateContainer re
  let cmd = podman args
  debug $ show cmd
  P.runProcess_ cmd
  where
    cname = unName $ ctx ^. name
    -- Delete a non-kept container and return the run args
    recreateContainer re = do
      deletePodmanPod (ctx ^. name)
      pure $ podmanRunArgs re rm ctx image
