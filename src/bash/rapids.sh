#!/bin/bash
SCALATEST_VERSION=3.0.5

# https://stackoverflow.com/a/246128
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do # resolve $SOURCE until the file is no longer a symlink
  DIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE" # if $SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
done
DIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"


function print_usage() {
  echo "Usage: rapids.sh [OPTION]"
  echo "Options:"
  echo "  --debug"
  echo "    enable bash tracing"
  echo "  -h, --help"
  echo "    prints this message"
  echo "  -m=MASTER, --master=MASTER"
  echo "    specify MASTER for spark command, default is local[-cluster], see --num-local-execs"
  echo "  -n, --dry-run"
  echo "    generates and prints the spark submit command without executing"
  echo "  -nle=N, --num-local-execs=N"
  echo "    specify the number of local executors to use, default is 2. If > 1 use pseudo-distributed"
  echo "    local-cluster, otherwise local[*]"
  echo "  -uecp, --use-extra-classpath"
  echo "    use extraClassPath instead of --jars to add RAPIDS jars to spark-submit (default)"
  echo "  -uj, --use-jars"
  echo "    use --jars instead of extraClassPath to add RAPIDS jars to spark-submit"
  echo "  --ucx-shim=spark<3xy>"
  echo "    Spark buildver to populate shim-dependent package name of RapidsShuffleManager."
  echo "    Will be replaced by a Boolean option"
  echo "  -cmd=CMD, --spark-command=CMD"
  echo "    specify one of spark-submit (default), spark-shell, pyspark, jupyter, jupyter-lab"
  echo "  -dopts=EOPTS, --driver-opts=EOPTS"
  echo "    pass EOPTS as --driver-java-options"
  echo "  -eopts=EOPTS, --executor-opts=EOPTS"
  echo "    pass EOPTS as spark.executor.extraJavaOptions"
  echo "  --gpu-fraction=GPU_FRACTION"
  echo "    GPU share per executor JVM unless local or local-cluster mode, see spark.rapids.memory.gpu.allocFraction"
}

# parse command line arguments
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        --debug)
            set -x
            ;;

        -n|--dry-run)
            DRY_RUN=true
            ;;

        -h|--help)
            print_usage
            exit 0
            ;;

        -uecp|--use-extra-classpath)
            USE_JARS=false
            ;;

        -nle=*|--num-local-execs=*)
            NUM_LOCAL_EXECS="${key#*=}"
            ;;

        -uj|--use-jars)
            USE_JARS=true
            ;;

        -cmd=*|--spark-command=*)
            SPARK_CMD="${key#*=}"
            ;;

        -m=*|--master=*)
            SPARK_MASTER="${key#*=}"
            ;;

        # TODO make this Boolean after adding util
        # in Shim to print shimId given SPARK_HOME
        --ucx-shim=*)
            UCX_SHIM="${key#*=}"
            ;;

        -dopts=*|--driver-opts=*)
            RAPIDS_DRIVER_OPTS="${key#*=}"
            ;;

        -eopts=*|--ececutor-opts=*)
            RAPIDS_EXEC_OPTS="${key#*=}"
            ;;

        --gpu-fraction=*)
            GPU_FRACTION="${key#*=}"
            ;;

        *) #NOPE
            break
            ;;
    esac

    shift
done

SPARK_HOME=${SPARK_HOME:-$HOME/gits/apache/spark}

# pre-requisite: `mvn package` has been run
SPARK_RAPIDS_HOME=${SPARK_RAPIDS_HOME:-$HOME/gits/NVIDIA/spark-rapids}

RAPIDS_SHELL_HOME=${RAPIDS_SHELL_HOME:-"$(dirname $(dirname $DIR))"}

SCALATEST_JARS=$(find ~/.m2 \
    -path \*/$SCALATEST_VERSION/\* -name \*scalatest\*jar -o \
    -path \*/$SCALATEST_VERSION/\* -name \*scalactic\*jar | tr -s "\n" ":")

RAPIDS_PLUGIN_JAR=$(find $SPARK_RAPIDS_HOME -regex ".*/rapids-4-spark_2.12-[0-9]+\.[0-9]+\.[0-9]+\(-SNAPSHOT\)?$SHIMVER.jar")

CUDF_JAR=$(find $SPARK_RAPIDS_HOME -name cudf\*jar)
if [ "$CUDF_JAR" == "" ]; then
    if [[ "$RAPIDS_PLUGIN_JAR" =~ .*/rapids-4-spark_2.12-([0-9]+.[0-9]+.[0-9]+(-SNAPSHOT)?).jar ]]; then
        RAPIDS_VERSION="${BASH_REMATCH[1]}"
    else
        echo "error: rapids version not detetected!"
        exit 1
    fi
    CUDF_JAR=$HOME/.m2/repository/ai/rapids/cudf/$RAPIDS_VERSION/cudf-$RAPIDS_VERSION-cuda11.jar
fi

RAPIDS_CLASSPATH="${RAPIDS_PLUGIN_JAR}:${CUDF_JAR}:${SPARK_RAPIDS_HOME}/tests/target/test-classes:${SCALATEST_JARS}"
RAPIDS_JARS="file://${RAPIDS_PLUGIN_JAR},file://${CUDF_JAR}"
FINAL_JAVA_OPTS=(
    "-ea"
    "-Duser.timezone=UTC"
    "-Dlog4j.debug=true"
    "-Dlog4j.configuration=file:${RAPIDS_SHELL_HOME}/src/conf/log4j.properties"
)

SPARK_CMD=${SPARK_CMD:-spark-shell}
USE_JARS=${USE_JARS:-false}

export IT_ROOT=${IT_ROOT:-"$SPARK_RAPIDS_HOME/integration_tests"}

# for all pyspark drivers
export PYTHONPATH="$PYTHONPATH:$IT_ROOT/src/main/python"

export LD_LIBRARY_PATH="$CONDA_PREFIX/lib"

case "$SPARK_CMD" in

    "spark-shell")
        # 	SPARK_CMD_RC="-I $RAPIDS_SHELL_HOME/src/scala/rapids.scala"
        ;;
    "spark-submit")
        ;;

    "pyspark")
        ;;

    "jupyter")
        export PYSPARK_DRIVER_PYTHON="$SPARK_CMD"
        export PYSPARK_DRIVER_PYTHON_OPTS="notebook"
        SPARK_CMD="pyspark"
        ;;

    "jupyter-lab")
        export PYSPARK_DRIVER_PYTHON="$SPARK_CMD"
        SPARK_CMD="pyspark"
        ;;

    *)
        echo -n "Unknown spark-rapids driver!"
        ;;
esac

NUM_LOCAL_EXECS=${NUM_LOCAL_EXECS:-0}
if [ "$SPARK_MASTER" == "" ]; then
    if ((NUM_LOCAL_EXECS > 0)); then
        SPARK_MASTER="local-cluster[$NUM_LOCAL_EXECS,2,4096]"
        GPU_FRACTION=$(<<< "scale=2; 0.96 / $NUM_LOCAL_EXECS" bc)
    else
        SPARK_MASTER="local[*]"
    fi
fi
GPU_FRACTION=${GPU_FRACTION:-"0.96"}

if [ "$USE_JARS" == "false" ]; then
    JAR_OPTS=(
        --driver-class-path "${RAPIDS_CLASSPATH}"
        --conf spark.executor.extraClassPath="${RAPIDS_CLASSPATH}"
    )
else
    JAR_OPTS=(--jars "${RAPIDS_CLASSPATH//:/,}")
fi

if [ "$UCX_SHIM" != "" ]; then
    UCX_OPTS=(
        --conf "spark.shuffle.manager=com.nvidia.spark.rapids.spark$UCX_SHIM.RapidsShuffleManager"
        --conf "spark.shuffle.service.enabled=false"
        --conf "spark.executorEnv.UCX_ERROR_SIGNALS="
        --conf "spark.executorEnv.UCX_MEMTYPE_CACHE=n"
        --conf "spark.sql.cache.serializer=com.nvidia.spark.ParquetCachedBatchSerializer"
    )
else
    UCX_OPTS=()
fi

COMMAND_ARR=(
    ${SPARK_HOME}/bin/${SPARK_CMD}
    ${SPARK_CMD_RC}
    --master \"$SPARK_MASTER\"
    --driver-memory 4g
    --driver-java-options \"${FINAL_JAVA_OPTS[*]} ${RAPIDS_DRIVER_OPTS}\"
    --conf spark.executor.extraJavaOptions=\"${FINAL_JAVA_OPTS[*]} ${RAPIDS_EXEC_OPTS}\"
    --conf spark.plugins=com.nvidia.spark.SQLPlugin
    --conf spark.rapids.memory.gpu.minAllocFraction=0
    --conf spark.rapids.memory.gpu.allocFraction=\"${GPU_FRACTION}\"
    --conf spark.rapids.sql.enabled=true
    --conf spark.rapids.sql.test.enabled=false
    --conf spark.rapids.sql.test.allowedNonGpu=org.apache.spark.sql.execution.LeafExecNode
    --conf spark.rapids.sql.explain=ALL
    --conf spark.rapids.sql.exec.CollectLimitExec=true
)
COMMAND_ARR+=("${JAR_OPTS[@]}")
COMMAND_ARR+=("${UCX_OPTS[@]}")
COMMAND_ARR+=("$@")

if [ "$DRY_RUN" == "true" ]; then
    set +x
    echo
    echo "************************************************************"
    echo -n "# Generating SparkSubmit command to start Spark RAPIDS: "
    echo
    echo "${COMMAND_ARR[*]}"
    echo
    echo "************************************************************"
else
    echo "#### Launchng generated Spark RAPIDS shell command"
    eval "${COMMAND_ARR[*]}"
fi
