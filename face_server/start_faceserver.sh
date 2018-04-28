#!/bin/bash
#从环境变量中读取等信息
#
#
echo "faceserver is Start!"
./faceserver -u 5000 -i $AppID -k $ApiKey -s $SecretKey
echo "faceserver is Exit!"
