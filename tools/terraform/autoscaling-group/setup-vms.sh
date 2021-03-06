#!/bin/sh
# vim:sw=2:et:

set -e

usage() {
  echo "Syntax: $(basename "$0") [-Dh] [-c <instance_count>] [-s <ssh_key>] <erlang_version> [<erlang_app_dir> ...]"
}

instance_count=1

while getopts "c:Dhs:" opt; do
  case $opt in
    h)
      usage
      exit
      ;;
    c)
      instance_count=$OPTARG
      ;;
    D)
      destroy=yes
      ;;
    s)
      ssh_key=$OPTARG
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      usage 1>&2
      exit 64
      ;;
    :)
      echo "Option -$OPTARG requires an argument." >&2
      usage 1>&2
      exit 64
      ;;
  esac
done
shift $((OPTIND - 1))

erlang_version=$1
if test -z "$erlang_version"; then
  echo "Erlang version is required" 1>&2
  echo 1>&2
  usage
  exit 64
fi
shift

terraform_dir=$(cd "$(dirname "$0")" && pwd)

canonicalize_erlang_version() {
  version=$1

  case "$version" in
    R[0-9]*)
      echo "$version" | sed -E 's/(R[0-9]+(:?A|B)[0-9]+).*/\1/'
      ;;
    [0-9]*)
      echo "$version" | sed -E 's/([0-9]+\.[0-9]+).*/\1/'
      ;;
  esac
}

find_ssh_key() {
  for file in ~/.ssh/*terraform* ~/.ssh/id_rsa ~/.ssh/id_ed25519; do
    if test -f "$file" && test -f "$file.pub"; then
      echo "$file"
      return
    fi
  done
}

list_dirs_to_upload() {
  if test -z "$MAKE"; then
    if gmake --version 2>&1 | grep -q "GNU Make"; then
      MAKE='gmake'
    elif make --version 2>&1 | grep -q "GNU Make"; then
      MAKE='make'
    fi
  fi

  template='dirs-to-upload.XXXX'
  manifest=$(mktemp -t "$template")
  for dir in "$@"; do
    (cd "$dir" && pwd) >> "$manifest"
    "$MAKE" --no-print-directory -C "$dir" fetch-test-deps >/dev/null
    cat "$dir/.erlang.mk/recursive-test-deps-list.log" >> "$manifest"
  done

  sorted_manifest=$(mktemp -t "$template")
  sort -u < "$manifest" > "$sorted_manifest"

  # shellcheck disable=SC2094
  while read -r dir; do
    grep -q "^$dir/" "$sorted_manifest" || echo "$dir"
  done < "$sorted_manifest" > "$manifest"

  awk '
  BEGIN {
    printf "[";
  }
  {
    if (NR > 1) {
      printf ",";
    }
    printf "\"" $0 "\"";
  }
  END {
    printf "]";
  }
  ' "$manifest"

  rm "$manifest" "$sorted_manifest"
}

init_terraform() {
  terraform init "$terraform_dir"
}

start_vms() {
  terraform apply \
    -auto-approve=true \
    -var="erlang_version=$erlang_branch" \
    -var="erlang_cookie=$erlang_cookie" \
    -var="erlang_nodename=control" \
    -var="ssh_key=$ssh_key" \
    -var="instance_count=$instance_count" \
    -var='dirs_to_upload='"$dirs_to_upload" \
    "$terraform_dir"
}

destroy_vms() {
  terraform destroy \
    -force \
    -var="erlang_version=$erlang_branch" \
    -var="erlang_cookie=$erlang_cookie" \
    -var="erlang_nodename=control" \
    -var="ssh_key=$ssh_key" \
    -var="instance_count=$instance_count" \
    -var='dirs_to_upload='"$dirs_to_upload" \
    "$terraform_dir"
}

erlang_branch=$(canonicalize_erlang_version "$erlang_version")
if test -z "$erlang_branch"; then
  echo "Erlang version '$erlang_version' malformed or unrecognized" 1>&2
  echo 1>&2
  usage
  exit 65
fi

if test -z "$ssh_key"; then
  ssh_key=$(find_ssh_key)
fi
if test -z "$ssh_key" || ! test -f "$ssh_key" || ! test -f "$ssh_key.pub"; then
  echo "Please specify a private SSH key using '-s'" 1>&2
  echo 1>&2
  usage
  exit 65
fi

erlang_cookie=$(cat ~/.erlang.cookie)
dirs_to_upload=$(list_dirs_to_upload "$@")

init_terraform

case "$destroy" in
  yes)
    destroy_vms
    ;;
  *)
    start_vms
    ;;
esac
