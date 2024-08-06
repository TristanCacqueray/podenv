let latest = "39"

let Prelude = ../Prelude.dhall

let Podenv = ../Podenv.dhall

let image-ref = \(ver : Text) -> "registry.fedoraproject.org/fedora${ver}"

let mkVolumes = \(ver : Text) -> [ "cache-dnf-${ver}:/var/cache/dnf" ]

let base-image =
      \(from : Text) ->
      \(ver : Text) ->
      \(post-task : Text) ->
      \(pre-task : Text) ->
      \(pkgs : List Text) ->
        Podenv.ContainerBuild::{
        , containerfile =
            ''
            FROM ${from}
            ARG USER_UID
            RUN ${./mkUser.dhall "fedora"}
            ${pre-task}
            RUN dnf update -y
            RUN dnf install -y ${Prelude.Text.concatSep " " pkgs}
            ENV USER=fedora
            ${post-task}
            ''
        , image_volumes = mkVolumes ver
        , image_home = Some "/home/fedora"
        , image_update = Some "dnf update -y"
        }

let image-with-post = \(ver : Text) -> base-image (image-ref (":" ++ ver)) ver

let image = \(ver : Text) -> base-image (image-ref (":" ++ ver)) ver ""

in  { image-ref, mkVolumes, base-image, image, image-with-post, latest }
