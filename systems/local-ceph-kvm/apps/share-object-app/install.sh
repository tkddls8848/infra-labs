# 사용자1 생성 및 버킷1에만 권한 부여
radosgw-admin user create --uid=user1 --display-name="User One"
radosgw-admin policy --bucket=bucket1 --add --uid=user1 --perm=readwrite

ACCESS_KEY1=$(radosgw-admin user info --uid=user1 | jq -r '.keys[0].access_key')
SECRET_KEY1=$(radosgw-admin user info --uid=user1 | jq -r '.keys[0].secret_key')
TUGT3H9GUS4R73CMUSKQ
1zdpdZI5CkN2bBIxafcgDcU5IQupygWYV2HcCfJk
# 버킷1의 기존 유저권한 분리 후 사용자1의 사용용 권한 부여
s3cmd mb s3://bucket1
OWNER_ID=$(radosgw-admin metadata get bucket:bucket1 | grep -o '"owner": *"[^"]*"' | cut -d'"' -f4)
radosgw-admin bucket unlink --uid=$OWNER_ID --bucket=bucket1
radosgw-admin bucket link --uid=user1 --bucket=bucket1
radosgw-admin bucket chown --uid=user1 --bucket=bucket1

# 사용자별 버킷 권한 부여
s3cmd setacl s3://버킷이름 --acl-grant=read:사용자명 # 다른 사용자에게 읽기 권한 부여
s3cmd setacl s3://버킷이름 --acl-grant=write:사용자명 # 다른 사용자에게 쓰기 권한 부여
s3cmd setacl s3://버킷이름 --acl-grant=all:사용자명 # 다른 사용자에게 전체 제어 권한 부여
s3cmd setacl s3://버킷이름 --acl-grant=read:사용자명 --recursive # 재귀적으로 버킷 내 모든 객체에 권한 부여

# 사용자별 버킷내 파일 권한 부여
s3cmd setacl s3://testbucket-s3cmd/ceph.svg --acl-grant=read:user1
s3cmd setacl s3://버킷이름/파일이름 --acl-grant=write:사용자명
s3cmd setacl s3://버킷이름/파일이름 --acl-grant=readwrite:사용자명
s3cmd setacl s3://testbucket-s3cmd/ceph.svg --acl-grant=all:user1