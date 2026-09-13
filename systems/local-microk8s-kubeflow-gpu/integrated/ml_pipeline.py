#!/usr/bin/env python3
"""
Kubeflow 테스트 데이터 파이프라인
간단한 머신러닝 워크플로를 구현한 예제입니다.
"""

import kfp
from kfp import dsl
from kfp.components import create_component_from_func
from typing import NamedTuple

# 1. 데이터 로드 컴포넌트
def load_data() -> NamedTuple('Outputs', [('dataset', str), ('num_samples', int)]):
    """샘플 데이터셋을 로드하는 컴포넌트"""
    
    import pandas as pd
    import numpy as np
    from sklearn.datasets import make_classification
    import os
    
    # 테스트용 분류 데이터셋 생성
    X, y = make_classification(
        n_samples=1000,
        n_features=20,
        n_informative=10,
        n_redundant=10,
        n_classes=2,
        random_state=42
    )
    
    # DataFrame으로 변환
    feature_names = [f'feature_{i}' for i in range(X.shape[1])]
    df = pd.DataFrame(X, columns=feature_names)
    df['target'] = y
    
    # 데이터를 CSV 파일로 저장
    output_path = '/tmp/dataset.csv'
    df.to_csv(output_path, index=False)
    
    print(f"데이터셋 생성 완료: {df.shape[0]} 샘플, {df.shape[1]-1} 피처")
    print(f"클래스 분포: {df['target'].value_counts().to_dict()}")
    
    return (output_path, df.shape[0])

# 2. 데이터 전처리 컴포넌트
def preprocess_data(
    dataset_path: str
) -> NamedTuple('Outputs', [('train_data', str), ('test_data', str), ('preprocessor', str)]):
    """데이터 전처리를 수행하는 컴포넌트"""
    
    import pandas as pd
    import numpy as np
    from sklearn.model_selection import train_test_split
    from sklearn.preprocessing import StandardScaler
    import pickle
    import os
    
    # 데이터 로드
    df = pd.read_csv(dataset_path)
    print(f"로드된 데이터 크기: {df.shape}")
    
    # 특성과 타겟 분리
    X = df.drop('target', axis=1)
    y = df['target']
    
    # 훈련/테스트 분할
    X_train, X_test, y_train, y_test = train_test_split(
        X, y, test_size=0.2, random_state=42, stratify=y
    )
    
    # 표준화
    scaler = StandardScaler()
    X_train_scaled = scaler.fit_transform(X_train)
    X_test_scaled = scaler.transform(X_test)
    
    # 처리된 데이터를 DataFrame으로 변환
    train_df = pd.DataFrame(X_train_scaled, columns=X.columns)
    train_df['target'] = y_train.values
    
    test_df = pd.DataFrame(X_test_scaled, columns=X.columns)
    test_df['target'] = y_test.values
    
    # 파일로 저장
    train_path = '/tmp/train_data.csv'
    test_path = '/tmp/test_data.csv'
    preprocessor_path = '/tmp/preprocessor.pkl'
    
    train_df.to_csv(train_path, index=False)
    test_df.to_csv(test_path, index=False)
    
    with open(preprocessor_path, 'wb') as f:
        pickle.dump(scaler, f)
    
    print(f"전처리 완료:")
    print(f"  - 훈련 데이터: {train_df.shape}")
    print(f"  - 테스트 데이터: {test_df.shape}")
    
    return (train_path, test_path, preprocessor_path)

# 3. 모델 훈련 컴포넌트
def train_model(
    train_data_path: str
) -> NamedTuple('Outputs', [('model', str), ('training_metrics', str)]):
    """머신러닝 모델을 훈련하는 컴포넌트"""
    
    import pandas as pd
    import numpy as np
    from sklearn.ensemble import RandomForestClassifier
    from sklearn.metrics import accuracy_score, classification_report, confusion_matrix
    import pickle
    import json
    
    # 훈련 데이터 로드
    train_df = pd.read_csv(train_data_path)
    X_train = train_df.drop('target', axis=1)
    y_train = train_df['target']
    
    print(f"훈련 데이터 크기: {X_train.shape}")
    
    # Random Forest 모델 훈련
    model = RandomForestClassifier(
        n_estimators=100,
        max_depth=10,
        random_state=42,
        n_jobs=-1
    )
    
    print("모델 훈련 시작...")
    model.fit(X_train, y_train)
    
    # 훈련 정확도 계산
    train_predictions = model.predict(X_train)
    train_accuracy = accuracy_score(y_train, train_predictions)
    
    # 특성 중요도 계산
    feature_importance = dict(zip(X_train.columns, model.feature_importances_))
    
    # 훈련 메트릭 저장
    training_metrics = {
        'train_accuracy': float(train_accuracy),
        'n_estimators': model.n_estimators,
        'max_depth': model.max_depth,
        'feature_importance': feature_importance
    }
    
    # 모델과 메트릭 저장
    model_path = '/tmp/trained_model.pkl'
    metrics_path = '/tmp/training_metrics.json'
    
    with open(model_path, 'wb') as f:
        pickle.dump(model, f)
    
    with open(metrics_path, 'w') as f:
        json.dump(training_metrics, f, indent=2)
    
    print(f"모델 훈련 완료 - 훈련 정확도: {train_accuracy:.4f}")
    print(f"상위 5개 중요 특성:")
    for feature, importance in sorted(feature_importance.items(), 
                                    key=lambda x: x[1], reverse=True)[:5]:
        print(f"  {feature}: {importance:.4f}")
    
    return (model_path, metrics_path)

# 4. 모델 평가 컴포넌트
def evaluate_model(
    model_path: str,
    test_data_path: str
) -> NamedTuple('Outputs', [('evaluation_metrics', str), ('predictions', str)]):
    """훈련된 모델을 평가하는 컴포넌트"""
    
    import pandas as pd
    import numpy as np
    from sklearn.metrics import accuracy_score, precision_score, recall_score, f1_score
    from sklearn.metrics import classification_report, confusion_matrix, roc_auc_score
    import pickle
    import json
    
    # 모델과 테스트 데이터 로드
    with open(model_path, 'rb') as f:
        model = pickle.load(f)
    
    test_df = pd.read_csv(test_data_path)
    X_test = test_df.drop('target', axis=1)
    y_test = test_df['target']
    
    print(f"테스트 데이터 크기: {X_test.shape}")
    
    # 예측 수행
    y_pred = model.predict(X_test)
    y_pred_proba = model.predict_proba(X_test)[:, 1]
    
    # 평가 메트릭 계산
    metrics = {
        'test_accuracy': float(accuracy_score(y_test, y_pred)),
        'test_precision': float(precision_score(y_test, y_pred)),
        'test_recall': float(recall_score(y_test, y_pred)),
        'test_f1': float(f1_score(y_test, y_pred)),
        'test_auc': float(roc_auc_score(y_test, y_pred_proba)),
        'confusion_matrix': confusion_matrix(y_test, y_pred).tolist(),
        'classification_report': classification_report(y_test, y_pred, output_dict=True)
    }
    
    # 예측 결과 저장
    predictions_df = pd.DataFrame({
        'actual': y_test.values,
        'predicted': y_pred,
        'probability': y_pred_proba
    })
    
    # 파일로 저장
    metrics_path = '/tmp/evaluation_metrics.json'
    predictions_path = '/tmp/predictions.csv'
    
    with open(metrics_path, 'w') as f:
        json.dump(metrics, f, indent=2)
    
    predictions_df.to_csv(predictions_path, index=False)
    
    print("모델 평가 완료:")
    print(f"  - 정확도: {metrics['test_accuracy']:.4f}")
    print(f"  - 정밀도: {metrics['test_precision']:.4f}")
    print(f"  - 재현율: {metrics['test_recall']:.4f}")
    print(f"  - F1 점수: {metrics['test_f1']:.4f}")
    print(f"  - AUC: {metrics['test_auc']:.4f}")
    
    return (metrics_path, predictions_path)

# 5. 모델 검증 컴포넌트
def validate_model(
    evaluation_metrics_path: str,
    min_accuracy: float = 0.8
) -> str:
    """모델 성능을 검증하고 배포 여부를 결정하는 컴포넌트"""
    
    import json
    
    # 평가 메트릭 로드
    with open(evaluation_metrics_path, 'r') as f:
        metrics = json.load(f)
    
    test_accuracy = metrics['test_accuracy']
    test_f1 = metrics['test_f1']
    
    print(f"모델 검증:")
    print(f"  - 테스트 정확도: {test_accuracy:.4f}")
    print(f"  - 최소 요구 정확도: {min_accuracy:.4f}")
    print(f"  - F1 점수: {test_f1:.4f}")
    
    # 배포 조건 확인
    if test_accuracy >= min_accuracy and test_f1 >= 0.7:
        decision = "APPROVED"
        message = f"모델이 배포 조건을 만족합니다 (정확도: {test_accuracy:.4f})"
    else:
        decision = "REJECTED"
        message = f"모델이 배포 조건을 만족하지 않습니다 (정확도: {test_accuracy:.4f})"
    
    print(f"배포 결정: {decision}")
    print(f"사유: {message}")
    
    return decision

# 컴포넌트 생성
load_data_op = create_component_from_func(
    load_data,
    base_image='python:3.9-slim',
    packages_to_install=[
        'pandas==1.5.3',
        'numpy==1.24.3',
        'scikit-learn==1.3.0'
    ]
)

preprocess_data_op = create_component_from_func(
    preprocess_data,
    base_image='python:3.9-slim',
    packages_to_install=[
        'pandas==1.5.3',
        'numpy==1.24.3',
        'scikit-learn==1.3.0'
    ]
)

train_model_op = create_component_from_func(
    train_model,
    base_image='python:3.9-slim',
    packages_to_install=[
        'pandas==1.5.3',
        'numpy==1.24.3',
        'scikit-learn==1.3.0'
    ]
)

evaluate_model_op = create_component_from_func(
    evaluate_model,
    base_image='python:3.9-slim',
    packages_to_install=[
        'pandas==1.5.3',
        'numpy==1.24.3',
        'scikit-learn==1.3.0'
    ]
)

validate_model_op = create_component_from_func(
    validate_model,
    base_image='python:3.9-slim'
)

# 파이프라인 정의
@dsl.pipeline(
    name='kubeflow-test-ml-pipeline',
    description='테스트용 머신러닝 데이터 파이프라인'
)
def ml_pipeline(
    min_accuracy: float = 0.8
):
    """완전한 머신러닝 파이프라인
    
    Args:
        min_accuracy: 모델 배포를 위한 최소 정확도 임계값
    """
    
    # 1. 데이터 로드
    load_data_task = load_data_op()
    load_data_task.set_display_name("데이터 로드")
    
    # 2. 데이터 전처리
    preprocess_task = preprocess_data_op(
        dataset_path=load_data_task.outputs['dataset']
    )
    preprocess_task.set_display_name("데이터 전처리")
    preprocess_task.after(load_data_task)
    
    # 3. 모델 훈련
    train_task = train_model_op(
        train_data_path=preprocess_task.outputs['train_data']
    )
    train_task.set_display_name("모델 훈련")
    train_task.after(preprocess_task)
    
    # 4. 모델 평가
    evaluate_task = evaluate_model_op(
        model_path=train_task.outputs['model'],
        test_data_path=preprocess_task.outputs['test_data']
    )
    evaluate_task.set_display_name("모델 평가")
    evaluate_task.after(train_task)
    
    # 5. 모델 검증
    validate_task = validate_model_op(
        evaluation_metrics_path=evaluate_task.outputs['evaluation_metrics'],
        min_accuracy=min_accuracy
    )
    validate_task.set_display_name("모델 검증")
    validate_task.after(evaluate_task)

# 파이프라인 컴파일 및 실행 함수
def compile_and_run_pipeline():
    """파이프라인을 컴파일하고 실행합니다."""
    
    import kfp
    
    # 파이프라인 컴파일
    pipeline_filename = 'ml_pipeline.yaml'
    kfp.compiler.Compiler().compile(ml_pipeline, pipeline_filename)
    print(f"파이프라인이 {pipeline_filename}으로 컴파일되었습니다.")
    
    # Kubeflow Pipelines 클라이언트 생성
    # 로컬 환경에서는 포트 포워딩된 주소 사용
    client = kfp.Client(host='http://localhost:1234')
    
    # 파이프라인 업로드 및 실행
    experiment_name = 'test-ml-experiment'
    run_name = 'test-ml-pipeline-run'
    
    try:
        # 실험 생성 (이미 존재하면 무시)
        experiment = client.create_experiment(experiment_name)
        print(f"실험 생성됨: {experiment_name}")
    except Exception as e:
        print(f"실험이 이미 존재하거나 생성 중 오류: {e}")
        experiment = client.get_experiment(experiment_name=experiment_name)
    
    # 파이프라인 실행
    run_result = client.run_pipeline(
        experiment_id=experiment.id,
        job_name=run_name,
        pipeline_package_path=pipeline_filename,
        params={'min_accuracy': 0.75}  # 테스트를 위해 낮은 임계값 설정
    )
    
    print(f"파이프라인 실행 시작됨: {run_name}")
    print(f"실행 ID: {run_result.id}")
    print(f"Kubeflow UI에서 확인: http://localhost:1234")
    
    return run_result

if __name__ == '__main__':
    # 파이프라인 컴파일 및 실행
    compile_and_run_pipeline()