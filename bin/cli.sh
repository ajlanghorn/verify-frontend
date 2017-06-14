#!/bin/bash

set -e
set -o pipefail

APP_NAME=${APP_NAME:-"front"}
# useful for testing
ROOT_PATH=${ROOT_PATH:="/"}
# store original pwd
export ORIGINAL_PWD=$(pwd)
# required for chroot on fedora
PATH="$PATH:/usr/sbin"

# Helper function that returns the real path, based on the given ROOT_PATH
_p() {
  echo "${ROOT_PATH%%/}${1}"
}

usage() {
  echo "Usage:"
  echo "  $APP_NAME run COMMAND [options]"
  echo "  $APP_NAME scale TYPE=NUM"
  echo "  $APP_NAME logs [--tail|-n NUMBER]"
  echo "  $APP_NAME config:get VAR"
  echo "  $APP_NAME config:set VAR=VALUE"
  echo "  $APP_NAME configure"
  echo "  $APP_NAME reconfigure"
}

DEFAULT_FILE=$(_p "/etc/default/${APP_NAME}")
SYSTEMD_DIR=$(_p "/etc/systemd/system")

. ${DEFAULT_FILE}

for file in $(_p "${APP_HOME}/.profile.d")/*.sh; do
  # .profile.d scripts assume HOME indicates the path to the app directory
  if [ -f $file ]; then HOME=${APP_HOME} . $file &>/dev/null; fi
done

# Source all environment variables for the app. This must be done as
# privileged user since the config variables are only readable by root.
PORT_WAS=$PORT
for file in $(_p "/etc/${APP_NAME}/conf.d")/*; do
  if [ -f $file ]; then . $file; fi
done

# Some actions require root privileges
ensure_root() {
  if [ $(id -u) -ne 0 ]; then
    echo "Error: You must be executing with root privileges to use this command."
    echo "Either log in as root, use sudo, or add sudo privileges for running ${APP_NAME} with your user."
    exit 1
  fi
}

# Return all the environment variables accessible to the app.
show_env() {
  env -i ROOT_PATH=${ROOT_PATH} ${0} run env | sort
}

logs() {
  if [ "$1" = "" ]; then
    for file in $(_p "/var/log/${APP_NAME}")/*.log ; do
      echo "==> ${file} <=="
      cat "${file}"
    done
  else
    tail $(_p "/var/log/${APP_NAME}")/*.log $@
  fi
}

tail_logs() {
  tail -f $(_p "/var/log/${APP_NAME}")/*.log
}

current_number_of_processes() {
  PROCESS_NAME="$1"
  if [ "${APP_RUNNER_TYPE}" = "upstart" ]; then
    echo $(ls -rv1 $(_p /etc/init/)${APP_NAME}-${PROCESS_NAME}-*.conf 2>/dev/null | head -1 | sed -r 's/.*\-([0-9]+)\.conf/\1/g')
  elif [ "${APP_RUNNER_TYPE}" = "systemd" ]; then
    echo $(ls -rv1 $SYSTEMD_DIR/${APP_NAME}-${PROCESS_NAME}-*.service 2>/dev/null | head -1 | sed -r 's/.*\-([0-9]+)\.service/\1/g')
  else
    echo $(ls -rv1 $(_p /etc/init.d/)${APP_NAME}-${PROCESS_NAME}-* 2>/dev/null | head -1 | sed -r 's/.*\-([0-9]+)/\1/g')
  fi

  return 0
}

update_port() {
  file="$1"
  process_name="$2"
  port="$3"
  index="$4"

  sed -i "s/PROCESS_NUM/${index}/g" "${file}"
  if [ "${process_name}" = "web" ]; then
    sed -i "s/PORT_NUM/${port}/g" "${file}"
  else
    sed -i "s/^env .*PORT_NUM.*$//g" "${file}"
    sed -i "s/^export PORT=PORT_NUM$//g" "${file}"
  fi
}

sysv_enable() {
  local name="$1"
  if [ "$APP_RUNNER_CLI" = "chkconfig" ] ; then
    $APP_RUNNER_CLI "$name" on
  elif [ "$APP_RUNNER_CLI" = "update-rc.d" ] ; then
    $APP_RUNNER_CLI "$name" defaults
  elif [ "$APP_RUNNER_CLI" = "systemctl" ] ; then
    $APP_RUNNER_CLI enable "$name"
  fi
}

sysv_disable() {
  local name="$1"
  if [ "$APP_RUNNER_CLI" = "chkconfig" ] ; then
    $APP_RUNNER_CLI "$name" off
  elif [ "$APP_RUNNER_CLI" = "update-rc.d" ] ; then
    $APP_RUNNER_CLI -f "$name" remove
  elif [ "$APP_RUNNER_CLI" = "systemctl" ] ; then
    $APP_RUNNER_CLI disable "$name"
  fi
}

scale_up() {
  PROCESS_NAME="${1}"
  CURRENT_SCALE=${2}
  NEW_SCALE=${3}
  SCALE_DELTA=${4}

  echo "Scaling up..."

  if [ "${APP_RUNNER_TYPE}" = "upstart" ]; then
    for i in $(seq ${SCALE_DELTA}); do
      index=$((${i} + ${CURRENT_SCALE}))
      PROCESS_ID="${APP_NAME}-${PROCESS_NAME}-${index}"
      cp $(_p "${APP_HOME}/vendor/pkgr/scaling/upstart/${APP_NAME}-${PROCESS_NAME}-PROCESS_NUM.conf") $(_p "/etc/init/${PROCESS_ID}.conf")
      port=$((${PORT} + ${index} - 1))

      update_port $(_p "/etc/init/${PROCESS_ID}.conf") "${PROCESS_NAME}" $port $index

      # directly call initctl instead of service, otherwise CentOS 6.x does not understand.
      $APP_RUNNER_CLI start "${PROCESS_ID}"
    done

    $APP_RUNNER_CLI start ${APP_NAME}-${PROCESS_NAME} || true
    $APP_RUNNER_CLI start ${APP_NAME} || true
  elif [ "$APP_RUNNER_TYPE" = "systemd" ]; then
    for i in $(seq ${SCALE_DELTA}); do
      index=$((${i} + ${CURRENT_SCALE}))
      PROCESS_ID="${APP_NAME}-${PROCESS_NAME}-${index}"
      cp ${source}/${APP_NAME}-${PROCESS_NAME}-PROCESS_NUM.service $SYSTEMD_DIR/${PROCESS_ID}.service
      port=$((${PORT} + ${index} - 1))

      update_port $SYSTEMD_DIR/${PROCESS_ID}.service "${PROCESS_NAME}" $port $index

      $APP_RUNNER_CLI enable "${PROCESS_ID}.service"
    done

    $APP_RUNNER_CLI daemon-reload
    $APP_RUNNER_CLI start ${APP_NAME}-${PROCESS_NAME}.service
    $APP_RUNNER_CLI start ${APP_NAME}.service
  else
    for i in $(seq ${SCALE_DELTA}); do
      index=$((${i} + ${CURRENT_SCALE}))
      PROCESS_ID="${APP_NAME}-${PROCESS_NAME}-${index}"
      cp $(_p "${APP_HOME}/vendor/pkgr/scaling/sysv/${APP_NAME}-${PROCESS_NAME}-PROCESS_NUM") $(_p "/etc/init.d/${PROCESS_ID}")
      port=$((${PORT} + ${index} - 1))

      update_port $(_p "/etc/init.d/${PROCESS_ID}") "${PROCESS_NAME}" $port $index

      chmod a+x $(_p "/etc/init.d/${PROCESS_ID}")
      sysv_enable ${PROCESS_ID}
      $(_p "/etc/init.d/${PROCESS_ID}") start
    done
  fi
  echo "--> done."
}

scale_down() {
  PROCESS_NAME="${1}"
  CURRENT_SCALE=${2}
  NEW_SCALE=${3}
  SCALE_DELTA=${4}

  echo "Scaling down..."
  for i in $(seq $(($SCALE_DELTA * -1))); do
    index=$((${i} + ${NEW_SCALE}))
    PROCESS_ID="${APP_NAME}-${PROCESS_NAME}-${index}"

    if [ "${APP_RUNNER_TYPE}" = "upstart" ]; then
      $APP_RUNNER_CLI stop "${PROCESS_ID}" || true # dont fail if server stopped differently
      rm -f $(_p "/etc/init/${PROCESS_ID}.conf")
    elif [ "${APP_RUNNER_TYPE}" = "systemd" ]; then
      $APP_RUNNER_CLI stop "${PROCESS_ID}.service" || true # dont fail if server stopped differently
      $APP_RUNNER_CLI disable "${PROCESS_ID}.service" || true
      rm -f $SYSTEMD_DIR/${PROCESS_ID}.service
    else
      $(_p "/etc/init.d/${PROCESS_ID}") stop
      sysv_disable ${PROCESS_ID}
      rm -f $(_p "/etc/init.d/${PROCESS_ID}")
    fi
  done
  echo "--> done."
}

# Scale processes
scale() {
  PROCESS_NAME="$1"
  NEW_SCALE="$2"

  CURRENT_SCALE=$(current_number_of_processes ${PROCESS_NAME})
  CURRENT_SCALE=${CURRENT_SCALE:="0"}
  SCALE_DELTA=$((${NEW_SCALE} - ${CURRENT_SCALE}))

  if [ "${APP_RUNNER_TYPE}" = "upstart" ]; then
    # copy initd
    cp $(_p "${APP_HOME}/vendor/pkgr/scaling/upstart/${APP_NAME}") $(_p "/etc/init.d/")
    chmod 0755 $(_p "/etc/init.d/${APP_NAME}")
    # copy master
    cp $(_p "${APP_HOME}/vendor/pkgr/scaling/upstart/${APP_NAME}.conf") $(_p "/etc/init/")
    # copy master process
    cp $(_p "${APP_HOME}/vendor/pkgr/scaling/upstart/${APP_NAME}-${PROCESS_NAME}.conf") $(_p "/etc/init/")
  elif [ "$APP_RUNNER_TYPE" = "systemd" ]; then
    local source=$(_p "${APP_HOME}/vendor/pkgr/scaling/systemd")
    # copy master
    cp ${source}/${APP_NAME}.service $SYSTEMD_DIR
    # copy master process
    cp ${source}/${APP_NAME}-${PROCESS_NAME}.service $SYSTEMD_DIR

    $APP_RUNNER_CLI enable ${APP_NAME}.service || true
    $APP_RUNNER_CLI enable ${APP_NAME}-${PROCESS_NAME}.service || true
  else
    cp $(_p "${APP_HOME}/vendor/pkgr/scaling/sysv/${APP_NAME}") $(_p /etc/init.d/)
    chmod a+x $(_p "/etc/init.d/${APP_NAME}")
    sysv_enable ${APP_NAME}
    cp $(_p "${APP_HOME}/vendor/pkgr/scaling/sysv/${APP_NAME}-${PROCESS_NAME}") $(_p /etc/init.d/)
    chmod a+x $(_p "/etc/init.d/${APP_NAME}-${PROCESS_NAME}")
    sysv_enable ${APP_NAME}-${PROCESS_NAME}
  fi

  if [ $SCALE_DELTA -gt 0 ]; then
    scale_up "${PROCESS_NAME}" $CURRENT_SCALE $NEW_SCALE $SCALE_DELTA
  elif [ $SCALE_DELTA -lt 0 ]; then
    scale_down "${PROCESS_NAME}" $CURRENT_SCALE $NEW_SCALE $SCALE_DELTA
  else
    echo "Nothing to do."
  fi
}

configure() {
  local installer_dir="$(_p "/usr/share/${APP_NAME}/installer")"
  if [ -d "$installer_dir" ] ; then
    ${installer_dir}/bin/run $@
  else
    echo "No installer has been configured for ${APP_NAME}"
  fi
}

reconfigure() {
  configure --reconfigure
}

while : ; do
  case "$1" in
    run)
      [ $# -lt 2 ] && usage
      COMMAND="$2"
      shift 2

      runnable=$(echo -n "exec")

      if [ -f $(_p "${APP_HOME}/vendor/pkgr/processes/${COMMAND}") ]; then
        # Command alias defined in Procfile
        runnable="${runnable}$(printf " %q" $(_p "${APP_HOME}/vendor/pkgr/processes/${COMMAND}") "$@")"
      else
        # Everything else.
        #
        # We're going through printf to preserve quotes in arguments. See
        # <http://stackoverflow.com/questions/10835933 /preserve-quotes-in-
        # bash-arguments>.
        runnable="${runnable}$(printf " %q" ${COMMAND} "$@")"
      fi

      # fix port
      export PORT=$PORT_WAS

      exec sh -c "cd $(_p ${APP_HOME}) && $runnable"

      break ;;

    scale)
      ensure_root

      shift
      for arg in "$@"; do
        [ "$arg" = "" ] && usage

        process=(${arg//=/ })
        process_name=${process[0]}
        new_scale=${process[1]}

        scale "${process_name}" "${new_scale}"
      done
      break ;;

    logs)
      shift
      if [ "$1" = "--tail" ]; then
        tail_logs
      else
        logs ${@}
      fi
      break;;

    config)
      show_env
      break;;

    config:set)
      [ $# -lt 2 ] && usage

      CONFIG=(${2//=/ })

      VAR=${CONFIG[0]:?"Invalid variable name"}
      VALUE="${2:$((${#VAR} + 1))}"

      CONFIG_FILE=$(_p "/etc/${APP_NAME}/conf.d/other")
      touch ${CONFIG_FILE}

      sed -i -r "s/^\s*export\s+${VAR}.*$//g" $(_p "/etc/${APP_NAME}/conf.d")/*

      echo "export ${VAR}=\"${VALUE}\"" >> "${CONFIG_FILE}"

      break;;

    config:get)
      [ $# -lt 2 ] && usage
      show_env | grep -e "^${2}=" | sed -r "s/^${2}=//"
      break;;

    configure)
      ensure_root

      configure $@
      break;;

    reconfigure)
      ensure_root

      reconfigure $@
      break;;

    *)
      usage
      break ;;
  esac
done
