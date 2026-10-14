# Super Slams — MiSTer FPGA 코어

> [!IMPORTANT]
> **취미로 만든 프로젝트입니다.**
> 개인이 순전히 취미로 만든 코어입니다. 버그 제보는 반갑게 받지만, **대응할 수도 있고 못 할 수도 있습니다.**
> 업데이트나 지원을 약속하지 않습니다.
>
> **이 코드로 이어서 개발하실 때는 꼭 출처를 남겨 주세요.**
> 이 저장소를 바탕으로 수정하거나 다른 코어를 만드실 때 출처(이 저장소 링크)를 밝혀 주시면 정말 감사하겠습니다.
> 라이선스(GPL-3.0)에 따라 원래의 저작권 표시와 이 프로젝트가 감사를 전한 분들의 출처도 함께 유지해 주세요.

*From TV Animation Slam Dunk - Super Slams* (Banpresto / Toei Animation /
Video System Co., 1995)를 MiSTer FPGA 에서 돌리기 위한 아케이드 코어입니다.
원래 기판은 Video System 의 **VSEP-26** 으로, 다음 부품으로 이루어져 있습니다.

    메인 CPU   Motorola 68000 @ 16 MHz
    사운드     Zilog Z80 @ 4 MHz + Yamaha YM2610 @ 8 MHz (FM / SSG / ADPCM-A / ADPCM-B)
    스프라이트 Fujitsu CG10103
    타일맵     VS920D / VS920F, VS9210 (타일 간접 참조)
    회전·확대  KONAMI 053936 (PSAC2) — 코트 배경 레이어
    입출력     VS9209
    화면       320 x 224, 약 60 Hz, 가로 화면

이 코어의 모든 회로는 MAME 드라이버(`suprslam.cpp`)와 그것이 부르는 장치
소스를 사양서로 삼아 HDL 로 새로 작성하거나, 검증된 오픈소스 CPU·사운드
코어를 연결해 만들었습니다. 게임 동작을 소프트웨어가 대신 계산하는 부분은
없습니다 — 기판이 하던 일은 전부 FPGA 안에서 일어납니다.

## 지원 게임

| MAME set | 공식 명칭 | 상태 |
|---|---|---|
| `suprslam` | From TV Animation Slam Dunk - Super Slams | 1차 완성. MiSTer 실기에서 코인 투입 → 팀 선택 → 경기 → 컨티뉴까지 플레이 확인, 어트랙트 화면 4 프레임이 MAME 와 픽셀 단위로 일치 |

MAME 드라이버에는 이 세트 하나만 있습니다. 배포용 `.mra` 는 `Super Slams.mra`
입니다.

## 설치 — ROM 만 넣으면 됩니다

이 배포본의 `SD/` 폴더는 MiSTer SD 카드의 루트(`/media/fat/`)와 같은 구조입니다.
**`SD/` 안의 내용을 SD 카드 루트에 그대로 복사**하면 됩니다.

```
SD/_Arcade/cores/SuperSlams.rbf                 코어 (빌드된 비트스트림)
SD/_Arcade/_Kaze's Cores/<게임 이름>.mra    게임 목록 (공식 명칭)
SD/games/mame/필요한_ROM.txt               넣어야 할 ROM zip 목록
```

1. `SD/` 의 내용을 SD 카드 루트에 복사합니다. 기존 파일은 덮어써도 됩니다.
2. 직접 마련한 MAME ROM 세트 zip 을 SD 카드의 `/games/mame/` 에 넣습니다.
   어떤 zip 이 필요한지는 `필요한_ROM.txt` 에 게임별로 적혀 있습니다.
   zip 은 MAME 세트 이름 그대로 두고, 압축을 풀지 않습니다.
3. MiSTer 메뉴에서 **Arcade → `_Kaze's Cores`** 로 들어가 게임을 고릅니다.

- `.rbf` 를 직접 실행하지 말고 `.mra` 로 실행하세요. ROM 로드와 DIP·OSD 기본값이
  `.mra` 에 들어 있습니다.
- 폴더 이름이 `_` 로 시작해야 MiSTer 메뉴에 보입니다. 이름을 바꾸지 마세요.


## 빌드 방법

필요한 것: **Intel Quartus Prime Lite Edition 17.0** (MiSTer 코어 표준 버전). 다른 버전에서도
합성은 될 수 있지만 검증한 버전은 17.0 입니다.

```sh
cd projects/vsystem/super_slams/targets/mister
quartus_sh --flow compile SuperSlams
```

결과물은 `projects/vsystem/super_slams/targets/mister/output_files/SuperSlams.rbf` 입니다. Quartus GUI 로
`SuperSlams.qpf` 를 열고 Compile 을 눌러도 같습니다.

- 디렉터리 구조를 그대로 유지해야 합니다. 프로젝트 파일이 `../../../../../third_party`,
  `../../../../../platforms/mister/sys` 를 상대 경로로 찾습니다.
- `build_id.v` 는 빌드 시작 때 `platforms/mister/sys/build_id.tcl` 이 자동으로 만듭니다.
- Quartus 17.0 의 fitter 가 드물게 내부 오류로 죽으면서도 정상 종료 코드를 남기는 경우가 있습니다.
  `.rbf` 의 생성 시각과 로그 끝부분을 확인하고, 그런 경우 한 번 더 빌드하면 됩니다.

직접 빌드한 `.rbf` 는 `SD/_Arcade/cores/` 의 같은 이름 파일과 바꿔 넣으면 됩니다.

## 디렉터리 구성

원래 저장소의 상대 경로를 그대로 유지했습니다. 빌드에 실제로 쓰이는 파일만 들어 있습니다.

```
LICENSE                              GPL-3.0 전문
README.md                            이 문서
SD/                                  SD 카드 루트에 복사할 설치 파일 (RBF, MRA, ROM 목록)
projects/vsystem/super_slams/
  rtl/                               기판 하드웨어 RTL (68000·Z80 버스, 비디오·사운드, 메모리 RTL)
  integration/                       ROM 다운로드 경로 (플랫폼 중립 어댑터)
  targets/mister/                    MiSTer 최상위 (.qpf .qsf .sdc .sv files.qip, PLL)
third_party/                         외부 IP (아래 "감사의 말과 사용한 코드" 참조)
platforms/mister/sys/                MiSTer framework (Template_MiSTer)
```

소스 주석에는 개발 중에 쓴 내부 문서 번호와 측정 기록이 그대로 남아 있습니다. 해당 개발
문서와 측정·분석 도구는 이 배포본에 포함하지 않았습니다. 빌드에는 영향이 없습니다.

## 작업 내역

### 2026-10-15 — CRT 화면 흔들림 수정, ROM 로딩 중 화면 신호 유지

- **CRT(아날로그 직결) 출력의 미세한 픽셀 흔들림을 고쳤습니다.** 픽셀 클럭 enable 이 48 MHz 의 소수 비율(픽셀 하나가 6.7 클럭)이라, 아날로그 출력에서 픽셀 폭이 6 클럭과 7 클럭으로 섞이고 그 패턴이 줄마다·프레임마다 밀렸습니다. 정지 화면에서 세로 경계가 미세하게 움직여 보이는 증상이었고 HDMI 에서는 보이지 않았습니다. 이제 줄 끝마다 같은 위상에서 다시 시작해 한 줄이 정확히 3057 클럭이 되고, 같은 열은 모든 줄과 프레임에서 같은 자리에 놓입니다. 래스터 크기와 픽셀 클럭은 그대로이고 프레임 속도만 59.9296 Hz 에서 59.9300 Hz 가 됩니다. 사용자가 CRT 에서 흔들림이 없어진 것을 확인했습니다.
- **ROM 을 읽어 들이는 동안에도 영상 동기 신호가 나갑니다.** 이전에는 로딩 중 코어 전체가 리셋에 잡혀 hsync/vsync 가 없었고, 그래서 MiSTer 의 OSD 로딩바를 그릴 화면이 없었습니다(HDMI 는 스케일러가 자체 타이밍을 만들어 보였습니다). 이제 로딩 중에는 검은 화면에 동기가 유지되어 CRT 에서도 로딩바가 보입니다. 사용자가 CRT 에서 확인했습니다. 리셋이 풀리는 순간의 코어 상태는 이전과 같게 맞췄습니다.
- 검증: 실제 모듈을 쓰는 시뮬레이션에서 리셋을 풀고 난 뒤 모든 출력이 "리셋 동안 래스터를 멈춰 둔" 기준과 클럭 단위로 같았고(약 960만 클럭을 비교했고, 일부러 틀리게 만든 대조군은 실패합니다), 모든 줄이 3057 클럭인 것을 확인했습니다. 053936 골든 비교(0 / 3,440,640 픽셀)도 그대로 통과했습니다. Quartus 전체 빌드는 에러 0, critical 경고 0, 타이밍 통과이고 경고 수(163)는 이전 빌드와 같습니다. 아날로그 파형을 계측한 것은 아닙니다.

### 2026-10-08

- **OSD 설정 저장 유지.** 이전에는 `Save settings` 로 저장해도 다음 실행 때 코어가 `.mra` 기본값을 다시 올려 저장값을 덮어썼습니다(MiSTer 는 저장 파일을 ROM 로드 전에 읽고, 코어가 보낸 status 로 128비트 전체를 교체합니다). 이제 저장된 설정이 있으면 기본값을 올리지 않습니다. 실기에서 저장 파일 값이 화면에 반영되는 것을 확인했습니다.

**2026-09-05 — 조사와 설계, 그리고 첫 비트스트림**

- MAME 드라이버와 스프라이트·053936·VS9209 장치 소스를 줄 번호와 함께
  하드웨어 사양으로 옮겨 적고, MAME 를 실행해 레지스터 접근·메모리 대역폭을
  실제로 측정한 뒤 설계를 시작했습니다.
- 대역폭 계산 결과(최악 약 11.2 M words/s)에 맞춰 코어 클럭과 SDRAM 컨트롤러,
  뱅크 배치를 정했습니다. 처음 고른 64 MHz 는 타이밍을 1.9 ns 놓쳐서, 68000·
  Z80·YM2610 클럭을 정수 분주로 정확히 얻을 수 있는 **48 MHz 단일 클럭**으로
  확정했습니다.
- 같은 제조사의 Power Spikes 코어에서 68000 래퍼, ROM 캐시, CRTC, 사운드 보드
  골격, ROM 로더를 가져와 매개변수만 맞췄고, SDRAM 컨트롤러는 Shadow Force
  코어의 것(타이밍을 클럭에서 계산하는 버전)을 썼습니다. 비디오 칩은 Power
  Spikes 와 하나도 공유하지 않아서 **ROZ 배경, FG 타일맵, VS9209, 스프라이트
  엔진 앞단은 새로 작성**했습니다. 053936 은 처음에는 MAME 의 계산식으로 직접
  만들었고, 2026-10-06 에 jotego 의 jt053936 으로 바꿨습니다(아래).
- 블록 RAM 으로 추론되지 않던 메모리 두 곳(경고 없이 플립플롭 11,264 개가 되던
  스프라이트 라인 버퍼 포함)을 바로잡았습니다.

**2026-09-05 ~ 09-06 — 첫 화면**

- MRA 스트림 정렬, 빠져 있던 메모리 리셋 연결을 고쳐 68000 이 부팅하고 ROM 7개
  영역이 SDRAM 에서 정확히 읽히는 것을 실기에서 확인했습니다.
- 화면이 안 나오던 원인은 레이어 렌더 트리거가 성립할 수 없는 조건(서로 다른
  타이밍의 두 펄스 AND)이었던 것으로, 시뮬레이션으로 재현하고 고쳤습니다.
- 어트랙트 전체 사이클이 나오고, **4 프레임이 MAME 와 픽셀 단위로 일치**
  (71,680 픽셀 중 불일치 0)했습니다.
- 스프라이트 xsize 해석을 바로잡아 팀 이름이 제대로 나오고, 처음으로 어트랙트를
  벗어나 경기가 시작됐습니다.

**2026-09-06 ~ 09-07 — 스프라이트와 속도**

- 경기 중 캐릭터가 잘리던 문제: 같은 스프라이트 리스트를 두 순회기가 그리던
  것을 하나로 합쳤습니다.
- 모든 스프라이트 타일 행이 16비트 한 워드씩 밀리던 문제: 체인 주소를 포인터가
  움직이기 한 클럭 전에 읽고 있었습니다. 기판 밖 시뮬레이션에서 결함을 재현한
  뒤 고쳤습니다.
- 빠른 움직임에서 타일 LUT 사본이 어긋나던 문제: 사본을 없애고 실시간 조회로
  바꿨습니다.
- 게임이 원래 속도의 58 % 로 돌던 문제: 68000 이 바쁠 때 여유가 전혀 없다는
  것을 측정한 뒤, 버스 우선권을 68000 에 주고 ROM 캐시를 16,384 엔트리로
  키웠습니다.
- 게임 자체의 I/O TEST 화면이 MAME 와 픽셀 단위로 일치하는 것을 확인했고,
  COIN3 와 SERVICE 입력 비트를 바로잡았습니다.

**2026-09-08 — 사운드, 1차 완성**

- "배경음 일부가 빠지고 효과음이 지글거린다"는 증상의 원인은 하나였습니다.
  사운드 분주 상수가 다른 클럭의 코어에서 그대로 넘어와 **YM2610 이 9.6 MHz,
  Z80 이 6 MHz** 로 돌고 있었고, 그 때문에 이 게임 믹스 에너지의 80 % 를 차지하는
  ADPCM-A 의 샘플 페치 창이 실제 페치 시간보다 짧아졌습니다. 8 MHz / 4 MHz 로
  정확히 고친 뒤, 늦게 도착한 샘플 수를 직접 세는 계측기로 0 을 확인했습니다
  (같은 결함을 일부러 주입하면 같은 계측기가 포화되는 것도 확인했습니다).
- 측정용 결함 주입기를 배포 코어에서 제거하고, 1차 완성으로 정리했습니다.

**2026-09-09 이후 — 정리**

- OSD 를 표준 구성(화면 비율 / Scandoubler / DIP / 일시정지 / 리셋, 디버그 항목은
  별도 페이지)으로 통일하고, 배포 `.mra` 를 다시 만들었습니다.
- 공용 IP 와 MiSTer 프레임워크를 공유 디렉터리로 옮긴 뒤 다시 빌드해 결과가
  바뀌지 않았음을 확인했습니다.

**2026-10-06 — 053936 을 jtcores 의 jt053936 으로 교체**

- 직접 만든 053936 좌표 계산을 jotego 의 `jt053936`(jtcores, 수정 없이 사용)으로
  바꿨습니다. 처음에는 "한 줄 앞선 가상 래스터"로 구동했고, 같은 날 실제 래스터
  구동으로 바꿨습니다: 칩은 CRTC 의 hsync·픽셀 클럭을 그대로 받고, 한 줄 앞서 그리는
  구조 때문에 vsync 만 정확히 한 줄 앞당겨 받습니다. 게임이 쓰는 레지스터 값(라인 RAM
  시작 위치 포함)을 그대로 쓰고, MAME 정렬 상수(-45/-21)와 값 덮어쓰기는 모두 없앴습니다.
  정렬은 동기 위치가 맞춥니다(게임 레지스터 값이 요구하는 위치, PCB 실측은 아님).
- 골든 대조: MAME 어트랙트에서 잡은 레지스터·라인 RAM 상태 36 프레임과 경계
  조건·무작위 상태를 합친 104 프레임, 871 만 픽셀에서 이전 구현·새 구현·MAME 계산식의
  좌표와 최종 BG 픽셀이 **모두 일치(불일치 0)**했습니다. 오프셋을 1 틀리게 넣은
  변이는 수백만 픽셀의 불일치로 잡혔습니다.
- 실기: 같은 장면에서 이전 RBF 와 BG 레이어가 픽셀 단위로 같았습니다(차이는 깜박이는
  글자와 스프라이트 애니메이션 위상뿐).
- 이 과정에서 어트랙트 약 2100 프레임부터 053936 의 라인 단위 모드가 실제로 켜진다는
  것을 새로 확인했습니다.


**2026-10-06 — 버튼 이름**

- 실기에서 첫 번째 버튼이 패스, 두 번째가 슛이었습니다. 배선은 맞았고 이름만 바뀌어
  있어서 `Pass, Shoot, Dash` 순서로 고쳤습니다.

## 감사의 말과 사용한 코드

먼저 **MAME 팀**에 깊이 감사드립니다. 이 코어는 처음부터 끝까지 MAME 의
드라이버와 장치 소스를 사양서로 삼아 만들어졌습니다. 메모리 맵, 레지스터 의미,
클럭, 스프라이트·타일·회전 레이어의 비트 배치까지, MAME 개발자들이 수십 년에
걸쳐 기록하고 다듬어 온 지식이 없었다면 시작조차 할 수 없었습니다. 또한 MAME 를
실행해 얻은 덤프는 픽셀 대조와 대역폭 측정의 기준이 되었습니다.

- 홈페이지: https://www.mamedev.org/
- 소스: https://github.com/mamedev/mame

### 사용한 서드파티 코드

| 이름 | 용도 | 저자 | 라이선스 | 출처 (커밋) | 사용한 파일 | 수정 여부 |
|---|---|---|---|---|---|---|
| fx68k | 메인 CPU (68000) | Jorge Cwik | GPL-3.0-only | [ijor/fx68k](https://github.com/ijor/fx68k) `0602ee4627b10f301298f2673d826cdd6baa9327` | `fx68k.sv`, `fx68kAlu.sv`, `uaddrPla.sv`, `microrom.mem`, `nanorom.mem` | `fx68k.sv` 에 읽기 전용 디버그 출력 포트 `dbg_d7` 추가 (`// LOCAL:` 표시, 동작 변경 없음) |
| T80 | 사운드 CPU (Z80) | Daniel Wallner, MiSTer-devel 유지보수자 | BSD-3-Clause 계열 | [MiSTer-devel/T80](https://github.com/MiSTer-devel/T80) `830fd0315f0af5cdbcb0e703f1cea3ce4e91f538` | `T80.vhd`, `T80_ALU.vhd`, `T80_MCode.vhd`, `T80_Pack.vhd`, `T80_Reg.vhd`, `T80pa.vhd` | 없음 |
| jt12 | YM2610 (FM / ADPCM-A / ADPCM-B, `jt10` 최상위) | Jose Tejada Gomez (jotego) | GPL-3.0 | [jotego/jt12](https://github.com/jotego/jt12) `4cf1c5b1426cbed74591ca344f96b769fb027269` | `jt10*.v`, `jt12_*.v`, `jt03_acc.v` | 있음 — `jt10.v`, `jt10_adpcm_drvA.v`, `jt12_top.v`, `jt12_kon.v`, `jt12_mmr.v`, `jt12_reg.v` 에 디버그 관측용 출력 포트만 추가 (기존 논리 변경 없음, 추가한 모든 줄에 `// LOCAL:` 표시). jt49 는 원본 그대로 |
| jt49 | YM2610 의 SSG 부분 | Jose Tejada Gomez (jotego) | GPL-3.0 | [jotego/jt49](https://github.com/jotego/jt49) `47301ed51374d6d41db4db846b7643fecf75e417` | `jt49*.v` (jt12 트리에 포함) | 없음 |
| jt053936 | KONAMI 053936 (PSAC2) 회전·확대 좌표 생성기 | Jose Tejada Gomez (jotego). 파일 머리말에 "Furrtek 의 모듈을 바탕으로 함" | GPL-3.0-or-later (SPDX) | [jotego/jtcores](https://github.com/jotego/jtcores) `62cacc840340ad1fe7d6be481d0f9bbebe835e7d`, `cores/rungun/hdl/jt053936.v` | `third_party/video/jt053936/jt053936.v` | 없음 (이 코어에 맞춘 구동은 `rtl/video/ss_psac.sv` 에서) |
| MiSTer 프레임워크 (`sys/`) | 플랫폼 (HPS 입출력, 영상 스케일러, 오디오 출력, OSD) | MiSTer-devel (Sorgelig 외) | GPL-2.0+ / GPL-3.0+ (파일별 헤더) | [MiSTer-devel/Template_MiSTer @ `54ac838e019d7fa07fbb40677a104cd6620d15c3` (2026-08-17, `sys/` 내용 일치로 식별)](https://github.com/MiSTer-devel/Template_MiSTer) | `sys/` 전체 | `sys.tcl` 의 경로 해석 2줄 수정 |

- **Jorge Cwik** 님, 사이클 단위로 정확한 68000 코어 fx68k 에 감사드립니다.
- **Daniel Wallner** 님과 T80 을 오랫동안 유지해 오신 MiSTer 커뮤니티에 감사드립니다.
- **Jose Tejada (jotego)** 님, jt12·jt49 로 YM2610 을 FPGA 에서 들을 수 있게 해 주셨고, jt053936 으로 053936 을 실제 칩 구조 그대로 쓸 수 있게 해 주셔서 감사합니다.
- **Furrtek** 님, 053936 실리콘을 분석해 jt053936 의 바탕이 된 모듈을 공개해 주셔서 감사합니다.
- **Sorgelig** 님과 MiSTer-devel 기여자 여러분, MiSTer 플랫폼과 프레임워크에 감사드립니다.

### 참고한 MAME 소스

코드는 복사하지 않았고, 아래 파일에서 하드웨어 사실(메모리 맵, 레지스터 의미,
비트 배치, 연산 방식)을 읽어 RTL 을 새로 작성했습니다. RTL 주석에 해당 파일과
줄 번호를 남겨 두었습니다.

| MAME 파일 | 라이선스 | copyright-holders | 참고한 내용 |
|---|---|---|---|
| `src/mame/vsystem/suprslam.cpp` | BSD-3-Clause | David Haywood | 드라이버 전체: 메모리 맵, 클럭, 인터럽트, 화면 타이밍, ROM 배치, 입력·DIP, 사운드 라우팅, 스프라이트 버퍼 처리 |
| `src/mame/vsystem/vsystem_spr.cpp` / `vsystem_spr.h` | BSD-3-Clause | Nicola Salmoria, David Haywood | CG10103 스프라이트 속성, 체인, 확대·축소 |
| `src/mame/vsystem/vsystem_spr2.h` | BSD-3-Clause | Nicola Salmoria, David Haywood | Power Spikes 의 스프라이트 칩과 다른 칩임을 확인하는 대조 |
| `src/mame/vsystem/pspikes.cpp` | BSD-3-Clause | Nicola Salmoria | 같은 제조사 기판과의 차이 대조 |
| `src/mame/vsystem/vs9209.cpp` | BSD-3-Clause | AJR | VS9209 입출력 포트 |
| `src/devices/video/k053936.cpp` | BSD-3-Clause | David Haywood | 053936 레지스터 표와 회전·확대 계산. jt053936 교체 때 골든 대조 기준 |
| `src/emu/drawgfxt.ipp` | BSD-3-Clause | Nicola Salmoria, Aaron Giles | 확대·축소 스케일러의 좌표 계산 |
| `src/emu/tilemap.cpp` | BSD-3-Clause | Aaron Giles | 타일맵 플립 규칙, ROZ 그리기 |
| `src/emu/video/generic.cpp` | BSD-3-Clause | Nicola Salmoria | 그래픽 레이아웃 |

MAME 실행 파일은 계측 도구로도 사용했습니다(Lua 스크립트로 레지스터 접근과
화면을 덤프). **FBNeo 는 이 코어 작업에서 읽지 않았습니다.**

## 라이선스

이 코어는 GPL-3.0 인 fx68k 를 포함하므로 **코어 전체가 GPL-3.0** 으로
배포됩니다. 저장소의 `LICENSE` 는 GPL-3.0 전문입니다. 서드파티 파일은 각자의
원래 저작권·라이선스 헤더를 그대로 유지하며(T80 은 BSD-3-Clause 계열,
MiSTer 프레임워크는 파일별 GPL-2.0+/GPL-3.0+), 이 프로젝트가 수정한 부분은
`// LOCAL:` 주석으로 표시되어 있습니다.

**게임 ROM 은 포함되어 있지 않습니다.** `.mra` 에는 파일 이름, CRC, 배치만
들어 있으며, ROM 은 정당하게 소유한 것을 직접 준비해야 합니다.

## 알려진 제한사항

- **1차 완성 단계입니다.** MAME 가 쓰는 값을 그대로 옮기는 것이 목표였고,
  실제 기판과의 직접 대조는 아직 하지 않았습니다. 68000 / Z80 / YM2610 클럭과
  전체 래스터 크기(456 x 262)는 MAME 값이며, MAME 자신도 이 클럭들에
  "not verified" 라고 적어 두었습니다.
- **사운드는 계측으로 검증했고, 귀로 원본 기판과 비교하지는 않았습니다.**
  보고된 두 증상(빠진 배경음, 지글거림)은 원인을 고친 뒤 측정상 사라졌습니다.
- 픽셀 일치는 어트랙트 4 프레임과 팀 선택·I/O TEST 화면에서 확인했습니다.
  모든 장면을 대조한 것은 아닙니다.
- VS920E 칩은 구현하지 않았습니다. MAME 도 이 칩을 장치로 모델링하지 않습니다.
- DIP 스위치는 기판처럼 **부팅할 때 한 번만** 읽습니다. 바꾼 뒤에는 리셋이
  필요합니다.
- **Analogue Pocket 은 지원하지 않습니다.** 현재 설계는 블록 RAM 을 Pocket 의
  약 1.7 배 사용합니다.
