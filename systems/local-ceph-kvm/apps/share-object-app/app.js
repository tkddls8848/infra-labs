// app.js
const express = require('express');
const AWS = require('aws-sdk');
const path = require('path');
const multer = require('multer');
const app = express();
const port = 3333;

// 로컬 테스트용 연결정보
const TEST_ACCESS_KEY = 'VRK4HK93D0XDQEANQQJ5';
const TEST_SECRET_KEY = 'qu5abjKhK2cDcGeMZaxJro9Nj8rA7VyDJudbK7Bd';
const TEST_ENDPOINT = 'http://192.168.57.10:7480';

// 고정된 Access Key
const FIXED_ACCESS_KEY = 'OSXLCURUM712A9VCV6AL';

// multer 설정 - 메모리 스토리지 사용 (1GB 제한)
const upload = multer({
  storage: multer.memoryStorage(),
  limits: {
    fileSize: 1024 * 1024 * 1024, // 1GB 파일 크기 제한
    files: 5, // 한번에 최대 5개 파일
    fieldSize: 10 * 1024 * 1024 // 필드당 최대 10MB
  }
});

// 미들웨어 설정 - body 크기 제한 증가
app.use(express.json({ limit: '50mb', charset: 'utf-8' }));
app.use(express.urlencoded({ limit: '50mb', extended: true, charset: 'utf-8' }));
app.use(express.static('public'));

// 타임아웃 설정 (10분)
app.use((req, res, next) => {
  req.setTimeout(600000); // 10분
  res.setTimeout(600000); // 10분
  next();
});

// 모든 응답에 UTF-8 charset 설정
app.use((req, res, next) => {
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  next();
});

// 버킷 접근 권한 검증 미들웨어
function validateBucketAccess(req, res, next) {
  const clientId = req.headers['x-client-id'];
  const bucketName = req.params.bucketName;
  
  if (!clientId) {
    return res.status(401).json({ error: 'Authentication required' });
  }
  
  // 클라이언트 ID에서 endpoint와 accessKeyId 추출
  const parts = clientId.split('_');
  if (parts.length < 2) {
    return res.status(400).json({ error: 'Invalid client ID' });
  }
  
  const accessKeyId = parts[parts.length - 1];
  const allowedBuckets = userBucketMap[accessKeyId] || [];
  
  if (!allowedBuckets.includes(bucketName)) {
    return res.status(403).json({ error: 'Access denied to this bucket' });
  }
  
  next();
}

// S3 클라이언트를 저장할 전역 변수
let s3Clients = {};

// API 라우트들
// 사용자-버킷 매핑 데이터 (실제로는 데이터베이스에 저장)
const userBucketMap = {
  'VRK4HK93D0XDQEANQQJ5': ['testbucket-s3cmd', 'bucket1', 'bucket2'],  // 사용자1은 버킷1, 버킷3만 접근 가능
  'TUGT3H9GUS4R73CMUSKQ': ['bucket1'],  // 사용자1은 버킷1만 접근 가능
  'LGIFOILXPN21VZK5N3PX': ['bucket2']   // 사용자2는 버킷2만 접근 가능
};

app.post('/api/connect', (req, res) => {
  const { endpoint, accessKeyId, secretAccessKey } = req.body;
  const clientId = `${endpoint}_${accessKeyId}`;
  
  try {
    s3Clients[clientId] = new AWS.S3({
      endpoint: endpoint,
      accessKeyId: accessKeyId,
      secretAccessKey: secretAccessKey,
      s3ForcePathStyle: true,
      signatureVersion: 'v4',
      httpOptions: {
        timeout: 600000, // 10분 타임아웃
        agent: false
      }
    });
    
    // 연결 테스트
    s3Clients[clientId].listBuckets((err, data) => {
      if (err) {
        delete s3Clients[clientId];
        res.status(400).json({ error: 'Connection failed', details: err.message });
      } else {
        // 사용자별 버킷 목록 필터링
        const allowedBuckets = userBucketMap[accessKeyId] || [];
        const filteredBuckets = data.Buckets.filter(bucket => 
          allowedBuckets.includes(bucket.Name)
        );
        
        res.json({ 
          success: true, 
          message: 'Connected successfully', 
          buckets: filteredBuckets,  // 필터링된 버킷만 반환
          clientId: clientId
        });
      }
    });
  } catch (error) {
    res.status(400).json({ error: 'Invalid configuration', details: error.message });
  }
});

app.get('/api/bucket/:bucketName/files', validateBucketAccess, (req, res) => {
  const clientId = req.headers['x-client-id'];
  const s3Client = s3Clients[clientId];
  
  if (!s3Client) {
    return res.status(400).json({ error: 'Not connected to Ceph storage' });
  }
  
  const bucketName = req.params.bucketName;
  const params = {
    Bucket: bucketName,
    MaxKeys: 1000
  };
  
  s3Client.listObjectsV2(params, (err, data) => {
    if (err) {
      res.status(400).json({ error: 'Failed to list files', details: err.message });
    } else {
      const files = data.Contents.map(file => ({
        key: decodeURIComponent(file.Key), // 한글 파일명 디코딩
        size: file.Size,
        lastModified: file.LastModified,
        etag: file.ETag
      }));
      res.json({ files });
    }
  });
});

app.get('/api/bucket/:bucketName/file/:fileKey/download-url', validateBucketAccess, (req, res) => {
  const clientId = req.headers['x-client-id'];
  const s3Client = s3Clients[clientId];
  
  if (!s3Client) {
    return res.status(400).json({ error: 'Not connected to Ceph storage' });
  }
  
  const { bucketName, fileKey } = req.params;
  
  // Content-Disposition 헤더를 추가하여 다운로드를 강제 (한글 파일명 지원)
  const params = {
    Bucket: bucketName,
    Key: fileKey,
    Expires: 3600,
    ResponseContentDisposition: `attachment; filename*=UTF-8''${encodeURIComponent(fileKey)}; filename="${encodeURIComponent(fileKey)}"`
  };
  
  try {
    const url = s3Client.getSignedUrl('getObject', params);
    res.json({ url });
  } catch (error) {
    res.status(400).json({ error: 'Failed to generate download URL', details: error.message });
  }
});

// 파일 업로드 API
app.post('/api/bucket/:bucketName/upload', validateBucketAccess, upload.single('file'), (req, res) => {
  const clientId = req.headers['x-client-id'];
  const s3Client = s3Clients[clientId];
  
  if (!s3Client) {
    return res.status(400).json({ error: 'Not connected to Ceph storage' });
  }
  
  const bucketName = req.params.bucketName;
  const file = req.file;
  
  if (!file) {
    return res.status(400).json({ error: 'No file uploaded' });
  }
  
  // 한글 파일명 처리
  const fileName = Buffer.from(file.originalname, 'latin1').toString('utf8');
  
  const params = {
    Bucket: bucketName,
    Key: fileName,
    Body: file.buffer,
    ContentType: file.mimetype + '; charset=utf-8',
    Metadata: {
      'originalname': encodeURIComponent(fileName)
    }
  };
  
  // 대용량 파일을 위한 옵션 추가
  const options = {
    partSize: 10 * 1024 * 1024, // 10MB 청크 크기
    queueSize: 4 // 동시 업로드 수
  };
  
  s3Client.upload(params, options, (err, data) => {
    if (err) {
      console.error('Upload error:', err);
      res.status(400).json({ error: 'Failed to upload file', details: err.message });
    } else {
      res.json({ 
        success: true, 
        message: 'File uploaded successfully',
        location: data.Location,
        key: data.Key,
        etag: data.ETag
      });
    }
  });
});

// 파일 삭제 API
app.delete('/api/bucket/:bucketName/file/:fileKey', validateBucketAccess, (req, res) => {
  const clientId = req.headers['x-client-id'];
  const s3Client = s3Clients[clientId];
  
  if (!s3Client) {
    return res.status(400).json({ error: 'Not connected to Ceph storage' });
  }
  
  const { bucketName, fileKey } = req.params;
  const params = {
    Bucket: bucketName,
    Key: fileKey
  };
  
  s3Client.deleteObject(params, (err, data) => {
    if (err) {
      res.status(400).json({ error: 'Failed to delete file', details: err.message });
    } else {
      res.json({ 
        success: true, 
        message: 'File deleted successfully',
        key: fileKey
      });
    }
  });
});

// 메인 페이지 라우트
app.get('/', (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

// 에러 핸들링 미들웨어
app.use((error, req, res, next) => {
  if (error instanceof multer.MulterError) {
    if (error.code === 'LIMIT_FILE_SIZE') {
      return res.status(400).json({ error: 'File too large. Maximum size is 1GB.' });
    }
    if (error.code === 'LIMIT_FILE_COUNT') {
      return res.status(400).json({ error: 'Too many files. Maximum 5 files at once.' });
    }
  }
  res.status(500).json({ error: 'Server error', details: error.message });
});

// 서버 시작
const server = app.listen(port, () => {
  console.log(`Ceph file browser app running at http://localhost:${port}`);
});

// 서버 타임아웃 설정 (10분)
server.timeout = 600000;