#!/bin/bash

CONFIG_FILE=$1
NAME=$(basename $CONFIG_FILE .conf)

#-----------------------------------------------------------------------------------------------------------------------

function ts {
  echo [`date '+%b %d %X'`] $NAME:
}

#-----------------------------------------------------------------------------------------------------------------------

function is_change_event {
  EVENT="$1"
  FILE="$2"

#  echo "EVENT=$EVENT"
#  echo "FILE=$FILE"

  # File events
  if [ "$EVENT" == "ATTRIB" ]
  then
    echo "$(ts) Detected file attribute change: $FILE"
  elif [ "$EVENT" == "CLOSE_WRITE,CLOSE" ]
  then
    EVENT=CLOSE_WRITE
    echo "$(ts) Detected new file: $FILE"
  elif [ "$EVENT" == "MOVED_TO" ]
  then
    echo "$(ts) Detected file moved into dir: $FILE"
  elif [ "$EVENT" == "MOVED_FROM" ]
  then
    echo "$(ts) Detected file moved out of dir: $FILE"
  elif [ "$EVENT" == "DELETE" ]
  then
    echo "$(ts) Detected deleted file: $FILE"

  # Directory events
  elif [ "$EVENT" == "ATTRIB,ISDIR" ]
  then
    echo "$(ts) Detected dir attribute change: $FILE"
  elif [ "$EVENT" == "CREATE,ISDIR" ]
  then
    echo "$(ts) Detected new dir: $FILE"
  elif [ "$EVENT" == "MOVED_TO,IS_DIR" ]
  then
    echo "$(ts) Detected dir moved into dir: $FILE"
  elif [ "$EVENT" == "MOVED_FROM,IS_DIR" ]
  then
    echo "$(ts) Detected dir moved out of dir: $FILE"
  elif [ "$EVENT" == "DELETE,ISDIR" ]
  then
    echo "$(ts) Detected deleted dir: $FILE" 

  else
    return 1
  fi

  return 0
}

#-----------------------------------------------------------------------------------------------------------------------

function check_config {
  if [[ ! -d "$WATCH_DIR" ]]; then
    echo "$(ts) WATCH_DIR specified in $CONFIG_FILE must be a directory."
    exit 1
  fi

  if [[ ! "$SETTLE_DURATION" =~ ^([0-9]{1,2}:){0,2}[0-9]{1,2}$ ]]; then
    echo "$(ts) SETTLE_DURATION must be defined in $CONFIG_FILE as HH:MM:SS or MM:SS or SS."
    exit 1
  fi

  if [[ ! "$MAX_WAIT_TIME" =~ ^([0-9]{1,2}:){0,2}[0-9]{1,2}$ ]]; then
    echo "$(ts) MAX_WAIT_TIME must be defined in $CONFIG_FILE as HH:MM:SS or MM:SS or SS."
    exit 1
  fi

  if [[ ! "$MIN_PERIOD" =~ ^([0-9]{1,2}:){0,2}[0-9]{1,2}$ ]]; then
    echo "$(ts) MIN_PERIOD must be defined in $CONFIG_FILE as HH:MM:SS or MM:SS or SS."
    exit 1
  fi

  if [ -z "$COMMAND" ]; then
    echo "$(ts) COMMAND must be defined in $CONFIG_FILE"
    exit 1
  fi
}

#-----------------------------------------------------------------------------------------------------------------------

function to_seconds {
  readarray elements < <(echo $1 | sed 's/:/\n/g' | tac)

  SECONDS=0
  POWER=1

  for (( i=0 ; i<${#elements[@]}; i++ )) ; do
    SECONDS=$(( 10#$SECONDS + 10#${elements[i]} * 10#$POWER ))
    POWER=$(( 10#$POWER * 60 ))
  done

  echo "$SECONDS"
}

#-----------------------------------------------------------------------------------------------------------------------

function wait_for_events_to_stabilize {
  start_time=$(date +"%s")

  while true
  do
    if read -t $SETTLE_DURATION RECORD
    then
      end_time=$(date +"%s")

      if [ $(($end_time-$start_time)) -gt $MAX_WAIT_TIME ]
      then
        echo "$(ts) Input directory didn't stabilize after $MAX_WAIT_TIME seconds. Triggering command anyway."
        break
      fi
    else
      echo "$(ts) Input directory stabilized for $SETTLE_DURATION seconds. Triggering command."
      break
    fi
  done
}

#-----------------------------------------------------------------------------------------------------------------------

function wait_for_minimum_period {
  last_run_time=$1

  time_since_last_run=$(($(date +"%s")-$last_run_time))
  if [ $time_since_last_run -lt $MIN_PERIOD ]
  then
    remaining_time=$(($MIN_PERIOD-$time_since_last_run))

    echo "$(ts) Waiting an additional $remaining_time seconds before running command"
  fi

  # Process events while we wait for $MIN_PERIOD to expire
  while [ $time_since_last_run -lt $MIN_PERIOD ]
  do
    remaining_time=$(($MIN_PERIOD-$time_since_last_run))

    read -t $remaining_time RECORD

    time_since_last_run=$(($(date +"%s")-$last_run_time))
  done
}

#-----------------------------------------------------------------------------------------------------------------------

echo "$(ts) Starting monitor for $CONFIG_FILE"

tr -d '\r' < $CONFIG_FILE > /tmp/$NAME.conf

. /tmp/$NAME.conf

check_config

SETTLE_DURATION=$(to_seconds $SETTLE_DURATION)
MAX_WAIT_TIME=$(to_seconds $MAX_WAIT_TIME)
MIN_PERIOD=$(to_seconds $MIN_PERIOD)

pipe=$(mktemp -u)
mkfifo $pipe

echo "$(ts) Waiting for changes to $WATCH_DIR..."
inotifywait -m -q --format '%e %f' $WATCH_DIR >$pipe &

last_run_time=0

while true
do
  if read RECORD
  then
    EVENT=$(echo "$RECORD" | cut -d' ' -f 1)
    FILE=$(echo "$RECORD" | cut -d' ' -f 2-)

    if ! is_change_event "$EVENT" "$FILE"
    then
      continue
    fi

    # Monster up as many events as possible, until we hit the either the settle duration, or the max wait threshold.
    wait_for_events_to_stabilize

    # Wait until it's okay to run the command again, monstering up events as we do so
    wait_for_minimum_period $last_run_time

    echo "$(ts) Running command"
    $COMMAND
    last_run_time=$(date +"%s")
  fi
done <$pipe