import React, { useState, useEffect, useRef } from 'react';
import { createRoot } from 'react-dom/client';
import './styles.css';

const FLUTTER_APP_URL = '/app/?embedded=1';
const DEMO_VIDEO_URL = '/demo-walkthrough.mp4';

const PRODUCT_STEPS = [
  ['캡처를 그대로 공유해요', '약속·예약·쿠폰·장소 화면 한 장이면 충분합니다.'],
  ['AI가 핵심 정보만 찾아요', '날짜, 시간, 장소와 해야 할 일을 자동으로 구조화합니다.'],
  ['필요한 것만 한 번 확인해요', '애매한 정보가 있을 때만 정확한 질문 하나를 건냅니다.'],
  ['캘린더와 알림으로 실행해요', '확인한 일정은 저장하고 적절한 순간에 다시 알려드립니다.'],
];

function easeInOutCubic(t) {
  return t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2;
}

function easeOutCubic(t) {
  return 1 - Math.pow(1 - t, 3);
}

function easeOutBack(t) {
  const c1 = 1.70158;
  const c3 = c1 + 1;
  return 1 + c3 * Math.pow(t - 1, 3) + c1 * Math.pow(t - 1, 2);
}

function clamp(v, min, max) {
  return Math.min(Math.max(v, min), max);
}

function OpenLoopSplashCanvas() {
  const canvasRef = useRef(null);
  const textRef = useRef(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext('2d');
    if (!ctx) return;

    let startTime = null;
    let animationFrameId = null;
    const duration = 1600; // ms

    const render = (now) => {
      if (!startTime) startTime = now;
      const elapsed = now - startTime;
      const progress = clamp(elapsed / duration, 0, 1);

      const size = 160;
      canvas.width = size * 2;
      canvas.height = size * 2;
      ctx.scale(2, 2);
      ctx.clearRect(0, 0, size, size);

      const centerX = size / 2;
      const centerY = size / 2;
      const radius = size * 0.31;
      const strokeWidth = size * 0.105;

      const arcProgress = easeInOutCubic(clamp((progress - 0.04) / 0.58, 0, 1));
      const orbitProgress = easeInOutCubic(clamp(progress / 0.68, 0, 1));
      const settleProgress = easeOutCubic(clamp((progress - 0.58) / 0.22, 0, 1));

      // 1. Scale Transition of mark
      let scale = 1.0;
      if (progress <= 0.72) {
        scale = 0.82 + 0.18 * easeOutBack(progress / 0.72);
      }
      ctx.save();
      ctx.translate(centerX, centerY);
      ctx.scale(scale, scale);
      ctx.translate(-centerX, -centerY);

      // 2. Draw Arc
      const startAngle = 0.45;
      const sweepAngle = Math.PI * 1.48;
      ctx.beginPath();
      ctx.arc(centerX, centerY, radius, startAngle, startAngle + sweepAngle * arcProgress, false);
      ctx.strokeStyle = '#ffffff';
      ctx.lineWidth = strokeWidth;
      ctx.lineCap = 'round';
      ctx.stroke();

      // 3. Draw Orbiting Dot & Motion Trails
      const orbitStart = -Math.PI * 0.72;
      const orbitEnd = -Math.PI * 0.11 + Math.PI * 2;
      const orbitAngle = orbitStart + (orbitEnd - orbitStart) * orbitProgress;
      const orbitRadius = radius * (1.42 - 0.28 * settleProgress);
      const dotX = centerX + Math.cos(orbitAngle) * orbitRadius;
      const dotY = centerY + Math.sin(orbitAngle) * orbitRadius;

      if (orbitProgress > 0.06 && orbitProgress < 0.96) {
        for (let i = 3; i >= 1; i--) {
          const trailAngle = orbitAngle - 0.13 * i;
          const trailX = centerX + Math.cos(trailAngle) * orbitRadius;
          const trailY = centerY + Math.sin(trailAngle) * orbitRadius;
          ctx.beginPath();
          ctx.arc(trailX, trailY, strokeWidth * (0.42 - i * 0.07), 0, Math.PI * 2);
          ctx.fillStyle = `rgba(255, 255, 255, ${0.06 * (4 - i)})`;
          ctx.fill();
        }
      }

      // Settle ripple wave
      if (settleProgress > 0 && settleProgress < 1) {
        ctx.beginPath();
        ctx.arc(dotX, dotY, strokeWidth * (0.48 + settleProgress * 1.1), 0, Math.PI * 2);
        ctx.fillStyle = `rgba(255, 255, 255, ${(1 - settleProgress) * 0.35})`;
        ctx.fill();
      }

      // Main Dot
      ctx.beginPath();
      ctx.arc(dotX, dotY, strokeWidth * 0.48, 0, Math.PI * 2);
      ctx.fillStyle = '#ffffff';
      ctx.fill();

      ctx.restore();

      // 4. Wordmark animation (Opacity & Slide-up)
      if (textRef.current) {
        let textOpacity = 0;
        let textOffsetY = 16;
        if (progress >= 0.58) {
          const tProgress = clamp((progress - 0.58) / 0.28, 0, 1);
          textOpacity = easeOutCubic(tProgress);
          textOffsetY = 16 * (1 - easeOutCubic(tProgress));
        }
        textRef.current.style.opacity = String(textOpacity);
        textRef.current.style.transform = `translateY(${textOffsetY}px)`;
      }

      if (progress < 1) {
        animationFrameId = requestAnimationFrame(render);
      }
    };

    animationFrameId = requestAnimationFrame(render);
    return () => {
      if (animationFrameId) cancelAnimationFrame(animationFrameId);
    };
  }, []);

  return (
    <div className="splash-motion-container">
      <canvas ref={canvasRef} className="splash-canvas" style={{ width: '160px', height: '160px' }} />
      <span ref={textRef} className="splash-title" style={{ opacity: 0 }}>OpenLoop</span>
    </div>
  );
}

function PhoneDevice({ mode, onVideoEnd }) {
  const stageRef = useRef(null);
  const videoRef = useRef(null);
  const [showSplash, setShowSplash] = useState(false);
  const [splashFading, setSplashFading] = useState(false);
  const prevModeRef = useRef(mode);

  useEffect(() => {
    const stage = stageRef.current;
    if (!stage) return undefined;

    const updateScale = () => {
      const scale = Math.min(stage.clientWidth / 393, stage.clientHeight / 852);
      stage.style.setProperty('--phone-scale', String(scale));
    };
    const observer = new ResizeObserver(updateScale);
    observer.observe(stage);
    updateScale();
    return () => observer.disconnect();
  }, []);

  // Video play/pause handling based on mode
  useEffect(() => {
    const video = videoRef.current;
    if (!video) return;

    if (mode === 'intro') {
      video.currentTime = 0;
      video.play().catch(() => {});
    } else {
      video.pause();
    }
  }, [mode]);

  // Handle splash transition with full motion graphics when user switches to interactive mode
  useEffect(() => {
    if (mode === 'interactive' && prevModeRef.current === 'intro') {
      setShowSplash(true);
      setSplashFading(false);
      const fadeTimer = setTimeout(() => {
        setSplashFading(true);
      }, 1600);
      const endTimer = setTimeout(() => {
        setShowSplash(false);
        setSplashFading(false);
      }, 1900);
      return () => {
        clearTimeout(fadeTimer);
        clearTimeout(endTimer);
      };
    }
    prevModeRef.current = mode;
  }, [mode]);

  return (
    <div className={`phone-stage ${mode === 'intro' ? 'is-intro' : 'is-interactive'}`} ref={stageRef}>
      <div className="phone-device">
        {/* Flutter App Iframe (백그라운드에서 미리 준비 완료) */}
        <iframe
          className={`phone-layer flutter-layer ${mode === 'interactive' ? 'is-active' : ''}`}
          src={FLUTTER_APP_URL}
          title="OpenLoop 실제 Flutter 앱"
          loading="eager"
          allow="camera; microphone; clipboard-read; clipboard-write; display-capture;"
        />

        {/* Video Demo Layer (영상 일시정지 불가 및 겹침 방지 처리) */}
        <div className={`phone-layer video-layer ${mode === 'intro' ? 'is-active' : ''}`}>
          <video
            ref={videoRef}
            src={DEMO_VIDEO_URL}
            playsInline
            muted
            autoPlay
            onEnded={onVideoEnd}
            style={{ pointerEvents: 'none', userSelect: 'none' }}
          />
        </div>

        {/* Authentic Splash Screen with Motion Graphics */}
        {showSplash && (
          <div className={`phone-layer splash-layer ${splashFading ? 'is-fading' : ''}`}>
            <OpenLoopSplashCanvas />
          </div>
        )}

        {/* iPhone 16 Frame Border */}
        <img className="device-frame-overlay" src="/iphone-16-frame.svg" alt="" aria-hidden="true" />
      </div>
    </div>
  );
}

function App() {
  const initialMode =
    typeof window !== 'undefined' &&
    new URLSearchParams(window.location.search).get('mode') === 'interactive'
      ? 'interactive'
      : 'intro';
  const [mode, setMode] = useState(initialMode);

  const handleSwitchToApp = () => {
    setMode('interactive');
  };

  const handleSwitchToIntro = () => {
    setMode('intro');
  };

  return (
    <main className={`site-shell mode-${mode}`}>
      <header className="site-header">
        <a className="brand" href="/" aria-label="OpenLoop 홈">
          <img className="brand-mark" src="/openloop-icon.png" alt="" aria-hidden="true" />
          <span>OpenLoop</span>
        </a>

        <div className="header-actions">
          {mode === 'intro' ? (
            <button
              type="button"
              className="action-btn cta-primary-btn"
              onClick={handleSwitchToApp}
            >
              <span className="btn-text-full">직접 체험하기</span>
              <span className="btn-text-short">체험하기</span>
              <span>→</span>
            </button>
          ) : (
            <div className="mode-toggle-group">
              <button
                type="button"
                className={`toggle-tab ${mode === 'intro' ? 'is-active' : ''}`}
                onClick={handleSwitchToIntro}
              >
                🎬 시연 영상
              </button>
              <button
                type="button"
                className={`toggle-tab ${mode === 'interactive' ? 'is-active' : ''}`}
                onClick={handleSwitchToApp}
              >
                📱 직접 체험
              </button>
            </div>
          )}
        </div>
      </header>

      <section className={`hero-container ${mode === 'intro' ? 'hero-intro' : 'hero-interactive'}`}>
        {/* Intro Top Heading Banner (Only visible in intro mode) */}
        {mode === 'intro' && (
          <div className="intro-banner-header">
            <h1 className="intro-title">
              캡처 한 장으로 끝나는 일정 관리,<br />
              <strong>OpenLoop</strong> 시연 영상
            </h1>
            <p className="intro-subtitle">
              대화 캡처 공유부터 AI 분석, 캘린더 등록까지 전 과정을 확인해보세요.
            </p>
          </div>
        )}

        <div className="hero-content-wrapper">
          {/* Left Column: Product Info & Steps */}
          <div className="hero-copy">
            <div className="hero-copy-inner">
              <div className="live-status-pill">
                <span className="live-pulse" />
                실제 앱을 직접 조작해볼 수 있습니다
              </div>
              <h1>
                캡처 한 장이,<br />
                <em>실행 가능한 일정으로.</em>
              </h1>
              <p className="hero-description">
                OpenLoop는 카톡·문자·SNS에 흩어진 약속과 기한을 이해하고,
                날짜·시간·장소와 다음 행동까지 정리해 주는 AI 액션 비서입니다.
              </p>

              <ol className="steps" aria-label="OpenLoop 사용 방법">
                {PRODUCT_STEPS.map(([title, detail], index) => (
                  <li key={title} style={{ animationDelay: `${(index + 1) * 120}ms` }}>
                    <b>{index + 1}</b>
                    <div>
                      <strong>{title}</strong>
                      <span>{detail}</span>
                    </div>
                  </li>
                ))}
              </ol>
            </div>
          </div>

          {/* Right/Center Column: iPhone Phone Device */}
          <div className="simulator-column">
            <PhoneDevice
              mode={mode}
              onVideoEnd={handleSwitchToApp}
            />

            {mode === 'intro' && (
              <div className="intro-bottom-cta">
                <button
                  type="button"
                  className="big-cta-btn"
                  onClick={handleSwitchToApp}
                >
                  <span>직접 화면을 터치하며 체험하기</span>
                  <span className="arrow-icon">→</span>
                </button>
              </div>
            )}
          </div>
        </div>
      </section>
    </main>
  );
}

createRoot(document.getElementById('root')).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
);
