#Dockerfile
#FROM openresty_face/base:v0.01
FROM daocloud.io/peizhiluo007/openresty:last
MAINTAINER peizhiluo007<25159673@qq.com>

#采用supervisor来管理多任务
#配置文件的路径变化了(since Supervisor 3.3.0)
COPY supervisord.conf /etc/supervisor/supervisord.conf
COPY check_lua/ /xm_workspace/xmcloud3.0/check_lua/
COPY face_server/ /xm_workspace/xmcloud3.0/face_server/
COPY _images/ /xm_workspace/xmcloud3.0/_images/
RUN	chmod 777 /xm_workspace/xmcloud3.0/check_lua/*
RUN	chmod 777 /xm_workspace/xmcloud3.0/face_server/*

EXPOSE 8001
#WORKDIR /xm_workspace/xmcloud3.0/common_lua/
#CMD ./sockproc /tmp/shell.sock && chmod 0666 /tmp/shell.sock && supervisord
WORKDIR /xm_workspace/xmcloud3.0/check_lua/
CMD ["supervisord"]
