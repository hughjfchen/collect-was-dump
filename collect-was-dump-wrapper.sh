#!/usr/bin/env bash

# some utility functions
is_uint() {
  case $1 in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# main working hourse
go() {
  local MYPID
  local FULLEXE
  local PROCESSUSER
  local CURRENTUSER
  local JVMVERSION
  local JVMNAME
  local JVMTYPE
  local DUMPDATE
  local DUMPTIME
  local THREADDUMPFILE
  local HEAPDUMPFILE


  MYPID=$1

  # is it a valid PID?
  [ ! -e /proc/"$MYPID" ] && echo "invalid PID $MYPID" && exit 125

  FULLEXE="$(readlink -f /proc/"$MYPID"/exe)"

  [ "$(echo "$FULLEXE" | awk -F'/' '{print $NF}')" != "java" ] && echo "the process $MYPID not a java process" && exit 125

  PROCESSUSER=$(ps -eo user,pid | awk -v mypid="$MYPID" '$2==mypid {print $1}')
  CURRENTUSER=$(id -nu)
  # the user running this script must be the same as the JVM process
  [ "$PROCESSUSER" != "$CURRENTUSER" ] && echo "the JVM process $MYPID user is $PROCESSUSER, your user name is $CURRENTUSER. It must be the same to run this script" && exit 126

  JVMNAME="$($FULLEXE -version 2>&1 | grep -v grep | grep ' VM ' | grep 'build')"

  # get the jvm type
  JVMTYPE=""
  for THEJVMTYPE in "OpenJDK" "HotSpot" "OpenJ9" "IBM J9"
  do
    if echo "$JVMNAME" | grep "$THEJVMTYPE" > /dev/null; then
      JVMTYPE="$THEJVMTYPE"
    fi
  done

  DUMPDATE=$(date "+%Y%m%d")
  DUMPTIME=$(date "+%H%M%S")

  # only IBM J9 VM is supported in this script.
  case "$JVMTYPE" in
    "IBM J9")
      # check jvm version, for IBM J9 VM, we only support jdk8 plus
      JVMVERSION="$($FULLEXE -fullversion 2>&1|awk -F'.' '{print $2}')"
      [ "$JVMVERSION" -lt 8 ] && echo "Only JDK 8 and above supported, however your JDK is $JVMVERSION" && exit 122

      THREADDUMPFILE="/tmp/javacore.$DUMPDATE.$DUMPTIME.$MYPID.txt"
      HEAPDUMPFILE="/tmp/heapdump.$DUMPDATE.$DUMPTIME.$MYPID.phd"

      ./jattach "$MYPID" threaddump > "$THREADDUMPFILE"
      ./jattach "$MYPID" dumpheap "$HEAPDUMPFILE" > /dev/null

      if [ -e "$THREADDUMPFILE" ] && [ -e "$HEAPDUMPFILE" ]; then
        echo "$THREADDUMPFILE"
        echo "$HEAPDUMPFILE"
      else
        echo "cannot find the generated javadump/heapdump files"
        exit 122
      fi
      ;;
    *)
      echo "Not supported JVM type, currently thi script only support IBM J9"
      exit 110
      ;;
  esac

}

# check command line args
# Given a PID or a WAS server name

if [ "$#" -eq 1 ]; then
  # currently, only linux is supported
  [ "$(uname -s)" != "Linux" ] && echo "This is a non-linux machine. Only Linux is supported." && exit 128

  # if the given argument is not a integer PID, try to treat it as a WebSphere application server name
  # and search the appropriate PID for that server
  GIVEN_PID=""
  if is_uint "$1"; then
    GIVEN_PID="$1"
  else
    # search the PID using the given argument as a WAS server name
    WAS_PID="$(ps -eo pid,cmd|grep -w "com.ibm.ws.bootstrap.WSLauncher"|awk -v myserver="$1" '$NF==myserver {print $1}')"
    if [ "X$WAS_PID" == "X" ]; then
      echo "The given argument neither a PID nor a valid WebSphere application server name, abort."
      exit 130
    else
      GIVEN_PID="$WAS_PID"
    fi
  fi

  go "$GIVEN_PID"
else
  echo "Usage: collect-java-dump <Java Process PID|WebSphere Application Server Name>"
  exit 129
fi
