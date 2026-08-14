#!/bin/bash
# linux/mac下运行脚本
# @author 47081
ARG_COUNT=$#
#echo $ARG_COUNT
if [ $ARG_COUNT -lt 1 ]; then
  echo "Usage example: ./run.sh com.netsdk.demo.RealPlayByDataType"
  exit 1
fi
#源码路径
source_path=./src/main/java
#依赖包路径
dependencies_path=./src/main/resources
#编译输出路径
out_path=./target

#检查编译输出路径是否存在，如果存在,删除重新创建
if [ -d $out_path ];then
    rm -rf $out_path
fi
mkdir $out_path
#复制resources下的jar包到编译目录
cp $dependencies_path/*.jar $out_path
#获得需要编译的java文件名称，输出到list.txt文件中
find $source_path -name "*.java" > $out_path/list.txt
cp=$source_path:
for file in $out_path/*.jar; do
    cp+=$file:
done
#javac编译
javac -encoding UTF-8 -d $out_path -cp $cp @$out_path/list.txt
#进入编译文件夹
cd $out_path
cp=.:
for file in ./*.jar; do
    cp+=$file:
done
java -Dfile.encoding=UTF-8 -cp $cp $1