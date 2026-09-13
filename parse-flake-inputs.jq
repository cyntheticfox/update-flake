#!/usr/bin/env jq -j -f
"input,rev,type,url\n" +
((.nodes.root.inputs) as $inputs
  | .nodes
  | to_entries
  | map(
    select(.key | in($inputs))
    | [ .key
    , if
        .value.locked.rev
      then
        .value.locked.rev
      else
        "null"
      end
    , .value.original.type
    , if .value.original.type == "github" then
        ( "https://api.github.com/repos/"
        + .value.original.owner
        + "/"
        + .value.original.repo
        + "/commits/"
        + (
            if .value.original.ref? then
              .value.original.ref
            elif .value.original.rev? then
              .value.original.rev
            else
              "HEAD"
            end
          )
        )
      elif .value.original.type == "gitlab" then
        ( "https://gitlab.com/api/v4/projects/"
        + .value.original.owner
        + "%2F"
        + .value.original.repo
        + "/repository/commits/"
        + (
            if .value.original.ref? then
              .value.original.ref
            elif .value.original.rev? then
              .value.original.rev
            else
              "HEAD"
            end
          )
        )
      elif .value.original.type == "sourcehut" then
        ( "https://"
        + .value.original.host
        + "/api/"
        + .value.original.owner
        + "/repos/"
        + .value.original.repo
        + "/log/"
        + (
            if .value.original.ref? then
              .value.original.ref
            elif .value.original.rev? then
              .value.original.rev
            else
              "HEAD"
            end
          )
        )
      elif .value.original.type == "git" or .value.original.type == "tarball" then
        .value.original.url
      else
        ("Bad type: \"" + .value.original.type + "\"")
      end
      ]
      | join(",")
    )
  | join("\n")) + "\n"

