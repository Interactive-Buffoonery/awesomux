#!/usr/bin/env bash

AWESOMUX_PRODUCTION_BUNDLE_ID="com.interactivebuffoonery.awesomux"
AWESOMUX_DEVELOPMENT_BUNDLE_ID="${AWESOMUX_PRODUCTION_BUNDLE_ID}.dev"

awesomux_worktree_id() {
  local root="$1"
  local canonical_root="$root"
  if [[ -d "$root" ]]; then
    canonical_root="$(cd "$root" && pwd -P)"
  fi
  printf '%s' "$canonical_root" | shasum -a 256 | cut -c1-12
}

awesomux_socket_namespace() {
  local worktree_id="$1"
  local prefix="${worktree_id:0:9}"
  local value=$((16#$prefix))
  local digits="0123456789abcdefghijklmnopqrstuvwxyz"
  local encoded=""
  local remainder

  while (( value > 0 )); do
    remainder=$((value % 36))
    encoded="${digits:remainder:1}${encoded}"
    value=$((value / 36))
  done
  printf '%07s\n' "${encoded:-0}" | tr ' ' 0
}

awesomux_checkout_profile() {
  local root="$1"
  local git_dir common_dir
  git_dir="$(git -C "$root" rev-parse --absolute-git-dir)"
  common_dir="$(git -C "$root" rev-parse --path-format=absolute --git-common-dir)"
  if [[ "$git_dir" == "$common_dir" ]]; then
    printf 'development\n'
  else
    printf 'development:%s\n' "$(awesomux_worktree_id "$root")"
  fi
}

awesomux_resolve_profile() {
  local profile="$1"
  local worktree_id=""

  case "$profile" in
    production)
      AWESOMUX_PROFILE_VALUE="production"
      AWESOMUX_PROFILE_BUNDLE_ID="$AWESOMUX_PRODUCTION_BUNDLE_ID"
      AWESOMUX_PROFILE_DISPLAY_NAME="awesoMux"
      AWESOMUX_PROFILE_SUPPORT_NAME="awesoMux"
      AWESOMUX_PROFILE_CONFIG_NAME="awesomux"
      AWESOMUX_PROFILE_SOCKET_NAME="amx"
      ;;
    development)
      AWESOMUX_PROFILE_VALUE="development"
      AWESOMUX_PROFILE_BUNDLE_ID="$AWESOMUX_DEVELOPMENT_BUNDLE_ID"
      AWESOMUX_PROFILE_DISPLAY_NAME="awesoMux (dev)"
      AWESOMUX_PROFILE_SUPPORT_NAME="awesoMux-dev"
      AWESOMUX_PROFILE_CONFIG_NAME="awesomux-dev"
      AWESOMUX_PROFILE_SOCKET_NAME="amx-dev"
      ;;
    development:*)
      worktree_id="${profile#development:}"
      if [[ ! "$worktree_id" =~ ^[0-9a-f]{12}$ ]]; then
        echo "invalid awesoMux runtime profile '$profile'" >&2
        return 2
      fi
      AWESOMUX_PROFILE_VALUE="$profile"
      AWESOMUX_PROFILE_BUNDLE_ID="${AWESOMUX_DEVELOPMENT_BUNDLE_ID}.${worktree_id}"
      AWESOMUX_PROFILE_DISPLAY_NAME="awesoMux (dev ${worktree_id:0:7})"
      AWESOMUX_PROFILE_SUPPORT_NAME="awesoMux-dev-${worktree_id}"
      AWESOMUX_PROFILE_CONFIG_NAME="awesomux-dev-${worktree_id}"
      AWESOMUX_PROFILE_SOCKET_NAME="$(awesomux_socket_namespace "$worktree_id")"
      ;;
    *)
      echo "invalid awesoMux runtime profile '$profile'" >&2
      return 2
      ;;
  esac
}

awesomux_print_profile() {
  printf 'profile=%s\n' "$AWESOMUX_PROFILE_VALUE"
  printf 'bundle=%s\n' "$AWESOMUX_PROFILE_BUNDLE_ID"
  printf 'display=%s\n' "$AWESOMUX_PROFILE_DISPLAY_NAME"
  printf 'support=%s\n' "$AWESOMUX_PROFILE_SUPPORT_NAME"
  printf 'config=%s\n' "$AWESOMUX_PROFILE_CONFIG_NAME"
  printf 'socket=%s\n' "$AWESOMUX_PROFILE_SOCKET_NAME"
}
