#!/usr/bin/env bash
# Module 5 Demo 2 — Storage recommender (teaching tool).
ask() { read -rp "$1 " R; echo "$R"; }
A1=$(ask "Single instance attached block, or shared? [block/shared/object]:")
case "$A1" in
  block)
    A2=$(ask "Need >16k IOPS or >1 GB/s? [y/n]:")
    [[ "$A2" == "y" ]] && echo "-> EBS io2 Block Express" || echo "-> EBS gp3"
    ;;
  shared)
    A2=$(ask "Linux NFS or Windows SMB? [linux/windows]:")
    [[ "$A2" == "linux" ]] && echo "-> EFS (One Zone for cost / Standard for HA)" \
                           || echo "-> FSx for Windows File Server"
    ;;
  object)
    A2=$(ask "Access pattern: hot, mixed, cold, archive?:")
    case "$A2" in
      hot)     echo "-> S3 Standard" ;;
      mixed)   echo "-> S3 Intelligent-Tiering" ;;
      cold)    echo "-> S3 Standard-IA or Glacier Instant Retrieval" ;;
      archive) echo "-> S3 Glacier Deep Archive" ;;
    esac
    ;;
esac
