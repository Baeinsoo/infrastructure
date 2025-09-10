import yaml
import pandas as pd
import os
import re
import sys

# Windows에서 UTF-8 출력 인코딩 설정
if sys.platform.startswith('win'):
    import codecs
    sys.stdout = codecs.getwriter('utf-8')(sys.stdout.detach())
    sys.stderr = codecs.getwriter('utf-8')(sys.stderr.detach())

def load_yaml(file_path):
    with open(file_path, 'r') as f:
        return yaml.safe_load(f)

def map_type_to_csharp(excel_type):
    """Excel 타입을 C# 타입으로 매핑"""
    type_mapping = {
        'string': 'string',
        'int': 'int',
        'float': 'float',
        'double': 'double',
        'bool': 'bool',
        'boolean': 'bool',
        'long': 'long',
        'short': 'short',
        'byte': 'byte',
        'decimal': 'decimal'
    }
    return type_mapping.get(excel_type.lower(), 'string')

def to_pascal_case(name):
    """문자열을 PascalCase로 변환"""
    # 이미 camelCase나 PascalCase인 경우 처리
    if '_' not in name and '-' not in name:
        # camelCase를 PascalCase로 변환
        return name[0].upper() + name[1:] if name else ''
    
    # 언더스코어나 하이픈을 기준으로 단어 분리하고 각 단어의 첫 글자를 대문자로
    words = re.split(r'[_-]', name)
    return ''.join(word.capitalize() for word in words if word)

def to_camel_case(name):
    """문자열을 camelCase로 변환"""
    pascal = to_pascal_case(name)
    return pascal[0].lower() + pascal[1:] if pascal else ''

# =============================================================================
# CSV 생성 관련 함수들
# =============================================================================

def read_excel_for_csv(import_path):
    """CSV 생성을 위한 엑셀 파일 읽기 (두 번째 행을 헤더로 사용)"""
    return pd.read_excel(import_path, header=1)

def apply_column_mapping(df, source_columns, target_columns):
    """컬럼 선택 및 이름 변경"""
    filtered_df = df[source_columns]
    filtered_df.columns = target_columns
    return filtered_df

def apply_filters(df, filters):
    """필터 조건 적용"""
    for column, condition in filters.items():
        df = df.query(condition.replace("value", column))
    return df

def export_to_csv(df, export_path, file_name):
    """CSV 파일로 내보내기"""
    # exportPath + /csv/filename.csv 경로 생성
    csv_path = os.path.join(export_path, "csv", f"{file_name}.csv")
    
    os.makedirs(os.path.dirname(csv_path), exist_ok=True)
    df.to_csv(csv_path, index=False, encoding="utf-8")
    print(f"[OK] Exported CSV: {csv_path}")

def process_csv_export(mapping):
    """CSV 내보내기 전체 프로세스"""
    print(f"  [CSV] Generating CSV for {mapping['name']}...")
    
    # 엑셀 파일 읽기
    df = read_excel_for_csv(mapping['importPath'])
    
    # 컬럼 매핑 적용
    filtered_df = apply_column_mapping(df, mapping['sourceColumns'], mapping['targetColumns'])
    
    # 필터 적용
    filters = mapping.get('filters', {})
    if filters:
        filtered_df = apply_filters(filtered_df, filters)
    
    # CSV로 내보내기 (name을 파일명으로 사용)
    export_to_csv(filtered_df, mapping['exportPath'], mapping['name'])

# =============================================================================
# C# 클래스 생성 관련 함수들
# =============================================================================

def read_excel_for_csharp(import_path):
    """C# 클래스 생성을 위한 엑셀 파일 읽기 (타입 정보 포함)"""
    return pd.read_excel(import_path, header=None)

def extract_type_and_column_info(df, source_columns):
    """엑셀에서 타입 정보와 컬럼 정보 추출"""
    types_row = df.iloc[0]
    columns_row = df.iloc[1]
    
    # 실제 컬럼명과 인덱스 매핑 생성
    column_name_to_index = {}
    for idx, col_name in enumerate(columns_row):
        if pd.notna(col_name):
            column_name_to_index[col_name] = idx
    
    # source_columns에 해당하는 타입 정보 수집
    column_info = []
    for source_col in source_columns:
        if source_col in column_name_to_index:
            col_index = column_name_to_index[source_col]
            excel_type = types_row.iloc[col_index] if col_index < len(types_row) else 'string'
            column_info.append({
                'source_name': source_col,
                'excel_type': str(excel_type),
                'index': col_index
            })
    
    return column_info

def generate_class_name(mapping_name):
    """매핑 이름에서 클래스명 생성"""
    # name을 그대로 클래스명으로 사용 (공백과 Mapping 제거 로직 불필요)
    return mapping_name

def generate_class_properties(column_info, target_columns):
    """클래스 프로퍼티 코드 생성"""
    properties = []
    for i, col_info in enumerate(column_info):
        if i < len(target_columns):
            csharp_type = map_type_to_csharp(col_info['excel_type'])
            property_name = to_pascal_case(target_columns[i])
            properties.append(f"        public {csharp_type} {property_name} {{ get; private set; }}")
    
    return properties

def build_csharp_class_code(class_name, properties):
    """C# 클래스 전체 코드 생성"""
    class_code = f"""using GameFramework;

namespace LOP.MasterData
{{
    public sealed class {class_name} : IMasterData
    {{
"""
    
    for prop in properties:
        class_code += prop + "\n"
    
    class_code += """    }
}"""
    
    return class_code

def save_csharp_class(class_code, export_path, file_name):
    """C# 클래스 파일 저장"""
    # exportPath + /cs/filename.cs 경로 생성
    cs_output_path = os.path.join(export_path, "cs", f"{file_name}.cs")
    
    os.makedirs(os.path.dirname(cs_output_path), exist_ok=True)
    
    with open(cs_output_path, 'w', encoding='utf-8') as f:
        f.write(class_code)
    
    print(f"[OK] Generated C# class: {cs_output_path}")
    return cs_output_path

def process_csharp_generation(mapping):
    """C# 클래스 생성 전체 프로세스"""
    print(f"  [CS] Generating C# class for {mapping['name']}...")
    
    # 엑셀 파일 읽기 (타입 정보 포함)
    df = read_excel_for_csharp(mapping['importPath'])
    
    # 타입 및 컬럼 정보 추출
    column_info = extract_type_and_column_info(df, mapping['sourceColumns'])
    
    # 클래스명 생성 (name을 그대로 사용)
    class_name = generate_class_name(mapping['name'])
    
    # 프로퍼티 생성
    properties = generate_class_properties(column_info, mapping['targetColumns'])
    
    # 클래스 코드 생성
    class_code = build_csharp_class_code(class_name, properties)
    
    # 파일 저장 (name을 파일명으로 사용)
    save_csharp_class(class_code, mapping['exportPath'], mapping['name'])

# =============================================================================
# 통합 처리 함수
# =============================================================================

def process_mapping(mapping):
    """매핑 정보를 기반으로 CSV와 C# 클래스 생성"""
    print(f"[PROCESS] Processing: {mapping['name']}")
    
    # C# 클래스 생성
    process_csharp_generation(mapping)
    
    # CSV 생성
    process_csv_export(mapping)
    
    print(f"[COMPLETE] Completed: {mapping['name']}\n")

# =============================================================================
# 메인 실행 함수
# =============================================================================

def process_yaml_file(yaml_file_path):
    """YAML 파일 하나를 처리"""
    print(f"[CONFIG] Processing YAML file: {yaml_file_path}")
    config = load_yaml(yaml_file_path)
    
    for mapping in config['mappings']:
        process_mapping(mapping)

def main():
    """메인 실행 함수"""
    print("[INFO] Starting Excel to CSV/C# conversion process...\n")
    
    yaml_files = ["../client_column_mapping.yaml", "../server_column_mapping.yaml"]
    
    for yaml_file in yaml_files:
        process_yaml_file(yaml_file)
    
    print("[SUCCESS] All processing completed successfully!")

if __name__ == "__main__":
    main()