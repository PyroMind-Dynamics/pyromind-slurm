#!/bin/bash



#### 需要修改地方
PKG_ROOT_PATH="/root/pyromind-slurm"
SLURM_DATA_STORE_BASE="/root/slurm_data"

echo "=========================================="
echo "Slurm Configuration Generator"
echo "=========================================="

pkill slurmdbd 
pkill slurmctld 
pkill munged 
pkill mysqld_safe
pkill mariadbd
pkill mysqld


HOST=$(hostname)
echo "Detected hostname: ${HOST}"

PKG_ROOT_PATH_BASE=$PKG_ROOT_PATH/base
PKG_ROOT_PATH_SLURM=$PKG_ROOT_PATH/slurm
SLURM_BASE_DATA_DIR="${SLURM_DATA_STORE_BASE}/${HOST}"
MYSQL_DATA_DIR="${SLURM_BASE_DATA_DIR}/mysql/data"

# apt update

DB_PASSWORD="Slurm2026"
echo "生成的数据库密码: $DB_PASSWORD"
echo "请保存此密码！"

export PATH=/usr/local/nvidia/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/nvidia/lib64:$LD_LIBRARY_PATH

cd $PKG_ROOT_PATH_BASE  && dpkg --configure -a &&  apt-get install -f -y  && dpkg -i libsigsegv2_*.deb && dpkg -i gawk_*.deb && dpkg -i *.deb && apt-get install -f -y


if [ -z "$(ls -A $MYSQL_DATA_DIR 2>/dev/null)" ]; then
    mkdir -p  $MYSQL_DATA_DIR && chown -R mysql:mysql  $MYSQL_DATA_DIR
    mariadb-install-db --datadir=$MYSQL_DATA_DIR --skip-test-db
    echo "✅ 初始化完成"
else
    echo "✅ 数据目录已存在且有内容，跳过初始化"
fi
mysqld_safe --user=root --datadir=$MYSQL_DATA_DIR --socket=/var/run/mysqld/mysqld.sock --pid-file=/var/run/mysqld/mysqld.pid &
sleep 10

# 检查数据库是否存在
DB_EXISTS=$(mysql -sse "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='$DB_NAME';" 2>/dev/null)

if [ -z "$DB_EXISTS" ]; then
    echo "📦 数据库 $DB_NAME 不存在，开始创建..."
    mysql -e "CREATE DATABASE IF NOT EXISTS slurm_acct_db;"
    mysql -e "CREATE USER IF NOT EXISTS 'slurm'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';"
    mysql -e "GRANT ALL PRIVILEGES ON slurm_acct_db.* TO 'slurm'@'localhost';"
    mysql -e "FLUSH PRIVILEGES;"
    echo "✅ 数据库和用户创建完成"
else
    echo "✅ 数据库 $DB_NAME 已存在，跳过创建"
fi


# 定义目录列表（使用 | 作为分隔符，避免与路径冲突）
directories="${SLURM_BASE_DATA_DIR}/munge:root:root:755|\
${SLURM_BASE_DATA_DIR}/slurmd/spool:root:root:755|\
${SLURM_BASE_DATA_DIR}/slurm/spool:root:root:755|\
${SLURM_BASE_DATA_DIR}/slurm/run:root:root:755|\
${SLURM_BASE_DATA_DIR}/slurm/log:root:root:755|\
${SLURM_BASE_DATA_DIR}/slurm/data:root:root:755|\
/etc/slurm:root:root:755|\
${SLURM_BASE_DATA_DIR}/slurm/log/slurm:root:root:755"

# 设置 IFS 为 | 分割
OLD_IFS="$IFS"
IFS='|'
set -- $directories
IFS="$OLD_IFS"

# 处理每个目录
for dir_config in "$@"; do
  # 使用 cut 或 awk 解析
  dir_path=$(echo "$dir_config" | cut -d':' -f1)
  owner=$(echo "$dir_config" | cut -d':' -f2)
  group=$(echo "$dir_config" | cut -d':' -f3)
  perm=$(echo "$dir_config" | cut -d':' -f4)
  
  # 检查目录是否存在
  if [ -d "$dir_path" ]; then
    echo "目录已存在，跳过: $dir_path"
  else
    echo "创建目录: $dir_path"
    mkdir -p "$dir_path"
    chown "$owner:$group" "$dir_path"
    chmod "$perm" "$dir_path"
    echo "已设置权限: $owner:$group $perm"
  fi
done

if [ ! -f "${SLURM_BASE_DATA_DIR}/munge/munge.key" ]; then
    dd if=/dev/random bs=1 count=1024 of=${SLURM_BASE_DATA_DIR}/munge/munge.key
    chmod 755 "${SLURM_BASE_DATA_DIR}/munge/munge.key"
else
    echo "${SLURM_BASE_DATA_DIR}/munge/munge.key 已存在，跳过拷贝"
fi

mkdir -p /run/munge
chmod 755 /run/munge
chmod 755 "${SLURM_BASE_DATA_DIR}"
chmod 600 "${SLURM_BASE_DATA_DIR}/munge/munge.key"

if ! pgrep -x "munged" > /dev/null; then
    munged \
      --key-file "${SLURM_BASE_DATA_DIR}/munge/munge.key" \
      --seed-file "${SLURM_BASE_DATA_DIR}/munge/munged.seed" \
      --log-file "${SLURM_BASE_DATA_DIR}/munge/munged.log" \
      --pid-file "${SLURM_BASE_DATA_DIR}/munge/munged.pid"
else
    echo "munged is already running"
fi


cd $PKG_ROOT_PATH_SLURM && dpkg -i *.deb  && apt-get install -f -y

# ============================================
# 生成 slurm.conf
# ============================================
cat > /etc/slurm/slurm.conf << SLURM_EOF
ClusterName=${HOST}
ControlMachine=${HOST}

SlurmUser=root
AuthType=auth/munge

StateSaveLocation=${SLURM_BASE_DATA_DIR}/slurm/spool/slurmctld
SlurmdSpoolDir=${SLURM_BASE_DATA_DIR}/slurm/spool/slurmd

SlurmctldPidFile=${SLURM_BASE_DATA_DIR}/slurm/run/slurmctld.pid
SlurmctldLogFile=${SLURM_BASE_DATA_DIR}/slurm/log/slurmctld.log
SlurmdLogFile=${SLURM_BASE_DATA_DIR}/slurm/log/slurmd.log

SchedulerType=sched/backfill
SelectType=select/cons_tres
SelectTypeParameters=CR_Core_Memory
ProctrackType=proctrack/linuxproc
TaskPlugin=task/none


# Accounting 配置
AccountingStorageType=accounting_storage/slurmdbd
AccountingStorageHost=localhost
AccountingStoragePort=6819
AccountingStorageEnforce=associations,limits
# AccountingStorageType=accounting_storage/filetxt
# AccountingStorageLoc=${SLURM_BASE_DATA_DIR}/var/slurm/data/slurm_jobs.log


SlurmdParameters=DynamicModules,AllowDynamicGres
SlurmdTimeout=300
SlurmctldTimeout=300
MaxNodeCount=512

GresTypes=gpu
PartitionName=dyn1 Nodes=ALL Default=YES MaxTime=INFINITE State=UP
SLURM_EOF

echo "✅ slurm.conf generated!"


# 生成 slurmdbd.conf
cat > /etc/slurm/slurmdbd.conf << EOF
AuthType=auth/munge
LogFile=${SLURM_BASE_DATA_DIR}/slurm/log/slurm/slurmdbd.log
PidFile=${SLURM_BASE_DATA_DIR}/slurm/run/slurmdbd.pid
StorageType=accounting_storage/mysql
StorageHost=127.0.0.1
StoragePort=3306
StorageUser=slurm
StoragePass=${DB_PASSWORD}
StorageLoc=slurm_acct_db
DbdHost=${HOST}
SlurmUser=root
DebugLevel=info
EOF

echo "✅ slurmdbd.conf generated!"

chmod 600 /etc/slurm/slurmdbd.conf
chown root:root /etc/slurm/slurmdbd.conf

cat > /etc/slurm/cgroup.conf << 'EOF'
CgroupPlugin=disabled
EOF

slurmdbd
sleep 5

slurmctld
sleep  5

echo "✅ Slurm services started successfully!"

