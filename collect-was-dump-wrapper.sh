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
  local PROCESSWD
  local PROCESSUSER
  local CURRENTUSER
  local JVMVERSION
  local JVMNAME
  local JVMTYPE
  local DUMPDATE
  #local DUMPTIME
  local ENV_IBM_JAVACOREDIR
  local ENV_IBM_HEAPDUMPDIR
  local ENV_TMPDIR
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

  PROCESSWD="$(pwdx "$MYPID" | awk '{print $NF}')"
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
  #DUMPTIME=$(date "+%H%M%S")

  # only IBM J9 VM is supported in this script.
  case "$JVMTYPE" in
    "IBM J9")
      # check jvm version, for IBM J9 VM, we only support jdk8 plus
      JVMVERSION="$($FULLEXE -fullversion 2>&1|awk -F'.' '{print $2}')"
      [ "$JVMVERSION" -lt 8 ] && echo "Only JDK 8 and above supported, however your JDK is $JVMVERSION" && exit 122

      # prepare the java surgery agent
      # i.e. link the jar to the home dir of the user
      rm -fr "$HOME"/surgery.jar
      ln -s surgery-no-doc.jar "$HOME"/surgery.jar

      "$FULLEXE" -jar "${java-surgeryPkg.src}" -command JavaDump -pid "$MYPID" > /dev/null 2>&1
      "$FULLEXE" -jar "${java-surgeryPkg.src}" -command HeapDump -pid "$MYPID" > /dev/null 2>&1

      # clean up the agent jar
      rm -fr "$HOME"/surgery.jar

      # need to wait some time for the dump files finishing generated
      # Do we really still need this?
      # comment out for now
      # sleep "$SECONDSTOSLEEP"

      # now find the generated dumps
      # the order to search is ENV IBM_XXXXDIR -> WorkingDir -> ENV TMPDIR -> /tmp
      # under environment varibale IBM_JAVACOREDIR/IBM_HEAPDUMPDIR/TMPDIR, the working directory of the process or /tmp
      ENV_IBM_JAVACOREDIR="$(strings /proc/"$MYPID"/environ | awk -F'=' '/IBM_JAVACOREDIR/ {print $2}')"
      ENV_IBM_HEAPDUMPDIR="$(strings /proc/"$MYPID"/environ | awk -F'=' '/IBM_HEAPDUMPDIR/ {print $2}')"
      ENV_TMPDIR="$(strings /proc/"$MYPID"/environ | awk -F'=' '/TMPDIR/ {print $2}')"

      # notice that the search path order is really very important.
      JAVACORESEARCHDIR=""
      for THEJAVACORESEARCHDIR in "/tmp" "$ENV_TMPDIR" "$PROCESSWD" "$ENV_IBM_JAVACOREDIR"
      do
        if [ "X$THEJAVACORESEARCHDIR" != "X" ] && [ -d "$THEJAVACORESEARCHDIR" ]; then
          JAVACORESEARCHDIR="$THEJAVACORESEARCHDIR"
        fi
      done

      HEAPDUMPSEARCHDIR=""
      for THEHEAPDUMPSEARCHDIR in "/tmp" "$ENV_TMPDIR" "$PROCESSWD" "$ENV_IBM_HEAPDUMPDIR"
      do
        if [ "X$THEHEAPDUMPSEARCHDIR" != "X" ] && [ -d "$THEHEAPDUMPSEARCHDIR" ]; then
          HEAPDUMPSEARCHDIR="$THEHEAPDUMPSEARCHDIR"
        fi
      done

      THREADDUMPFILE=$(find "$JAVACORESEARCHDIR" ! -path "$JAVACORESEARCHDIR" -prune -name "javacore.$DUMPDATE.*.$MYPID.*" -print0 | xargs -r0 ls -t | head -1)
      HEAPDUMPFILE=$(find "$HEAPDUMPSEARCHDIR" ! -path "$HEAPDUMPSEARCHDIR" -prune -name "heapdump.$DUMPDATE.*.$MYPID.*" -print0 | xargs -r0 ls -t | head -1)

      if [ "X$THREADDUMPFILE" == "X" ] && [ "X$HEAPDUMPFILE" == "X" ]; then
        echo "cannot find the generated javadump/heapdump files for IBM J9 VM"
        exit 122
      else
        echo "$THREADDUMPFILE"
        echo "$HEAPDUMPFILE"
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
