#!/bin/bash

# 스크립트 실행 중 에러 발생 시 종료
set -e

# 1. 가상환경이 없으면 생성
if [ ! -d "venv" ]; then
  echo "[SETUP] Creating virtual environment..."
  python -m venv venv
fi

# 2. 가상환경 활성화
echo "[SETUP] Activating virtual environment..."
if [ -f "venv/Scripts/activate" ]; then
  source venv/Scripts/activate
  echo "가상환경이 활성화되었습니다 (Windows)."
elif [ -f "venv/bin/activate" ]; then
  source venv/bin/activate
  echo "가상환경이 활성화되었습니다 (Linux/Mac)."
else
  echo "activate 스크립트를 찾을 수 없습니다."
  exit 1
fi

echo "현재 VIRTUAL_ENV: $VIRTUAL_ENV"
echo "Python 실행 파일: $(which python)"
echo "Pip 실행 파일: $(which pip)"

# 3. 의존성 설치
if [ -f "requirements.txt" ]; then
  echo "[SETUP] Installing dependencies from requirements.txt..."
  pip install -r requirements.txt
else
  echo "[WARNING] requirements.txt not found. Skipping pip install."
fi

# 4. 실행
echo "[RUN] Running main.py..."
python main.py

# 5. 결과물 복사
echo "[COPY] Copying output files to client and server directories..."
echo "  [CSV] Copying CSV files..."
cp -rv ../output/client/csv/* ../../LeagueOfPhysical-Client/Assets/StreamingAssets/MasterData/
cp -rv ../output/server/csv/* ../../LeagueOfPhysical-Server/Assets/StreamingAssets/MasterData/

echo "  [CS] Copying C# class files..."

mkdir -p ../../LeagueOfPhysical-Client/Assets/Scripts/MasterData/generated
cp -rv ../output/client/cs/* ../../LeagueOfPhysical-Client/Assets/Scripts/MasterData/generated/

mkdir -p ../../LeagueOfPhysical-Server/Assets/Scripts/MasterData/generated
cp -rv ../output/server/cs/* ../../LeagueOfPhysical-Server/Assets/Scripts/MasterData/generated/

# 종료 대기
read -p "프로그램이 종료되었습니다. 창을 닫으려면 Enter 키를 누르세요." || true