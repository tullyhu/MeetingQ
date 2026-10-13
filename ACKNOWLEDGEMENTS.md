# 开源致谢 / Acknowledgements

MeetingQ 使用了以下开源组件与模型，在此致谢。

## FluidAudio

- 项目：https://github.com/FluidInference/FluidAudio
- 许可证：Apache License 2.0
- 用途：设备端说话人分离的推理运行时与模型分发（Swift + CoreML/ANE）

## CAM++ 说话人声纹模型

- 项目：阿里达摩院 3D-Speaker / CAM++（经 FluidAudio 转换为 CoreML fp16）
- 许可证：Apache License 2.0
- 用途：192 维说话人声纹 embedding，完全在设备端运行，不会上传任何音频

## pyannote segmentation（间接）

- 项目：https://github.com/pyannote/pyannote-audio
- 许可证：MIT License
- 用途：FluidAudio 语音分段管线的基础模型设计

---

以上组件的许可证全文见其各自项目仓库，**许可证全文也已随应用打包**（`MeetingQ.app/Contents/Resources/Licenses/`，源码仓库内为 `Resources/Licenses/`）。声纹数据仅为数学特征向量，保存在本机，无法还原为语音，也不会上传。
