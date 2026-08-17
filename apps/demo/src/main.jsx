import React, { useMemo, useState } from 'react';
import { createRoot } from 'react-dom/client';
import './styles.css';

const scenarios = [
  {
    id: 'resolved', label: '최종 합의 찾기', eyebrow: 'APPOINTMENT',
    source: ['민수 · 이번 주 토요일 6시?', '나 · 나 그날 알바 6시까지임', '민수 · 그럼 7시 성수 난포 ㄱ', '민수 · 7시 예약했음'],
    title: '난포 저녁 약속', when: '8월 15일 토요일 · 19:00', place: '난포 성수', confidence: 99,
    note: '18:00은 거절되고 19:00 예약이 최종 합의로 확인됐어요.', actions: ['캘린더', '1시간 전 알림', '완료 확인'],
  },
  {
    id: 'deadline', label: '포스터 마감', eyebrow: 'DEADLINE',
    source: ['제1회 일상뒤집기 AI 공모전', '접수 마감 8월 22일 23:59', '사업 소개서 · HTML 프로토타입 · 한 줄 소개'],
    title: 'AI 공모전 제출', when: '8월 22일 · 23:59 마감', place: '온라인 제출', confidence: 96,
    note: '마감 일정과 필수 제출물 3개를 함께 찾았어요.', actions: ['D-7 알림', 'D-3 알림', '체크리스트 3개'],
  },
  {
    id: 'ambiguous', label: '애매함 처리', eyebrow: 'NEEDS INPUT',
    source: ['유진 · 토요일 저녁에 성수에서 만나자', '나 · 좋아!'],
    title: '성수 저녁 약속', when: '이번 주 토요일 · 시간 미정', place: '성수', confidence: 42,
    note: '날짜와 장소는 확실하지만 시간만 확인이 필요해요.', choices: ['18:00', '19:00', '20:00'], actions: ['Open Loop로 저장'],
  },
  {
    id: 'purchase', label: '구매·반품 기한', eyebrow: 'PURCHASE',
    source: ['[쿠팡] 주문 완료 안내', '무선 노이즈캔슬링 헤드폰', '반품/교환 가능 기한: 8월 25일까지'],
    title: '헤드폰 구매', when: '8월 25일 · 반품 기한', place: '쿠팡', confidence: 98,
    note: '주문 품목과 반품 기한 D-1 알림을 추출했어요.', actions: ['구매 내역 조회', 'D-1 반품 알림'],
  },
  {
    id: 'reservation', label: '항공·숙박 예약', eyebrow: 'RESERVATION',
    source: ['[대한항공] 항공권 예약 안내', '김포 → 제주 8월 20일 14:30', '예약번호 KE1234 · 탑승구 12'],
    title: '제주 항공편 예약', when: '8월 20일 · 14:30', place: '김포공항 국내선', confidence: 99,
    note: '탑승 시간과 출발 2시간 전 체크인 알림을 준비했어요.', actions: ['캘린더 등록', 'T-2h 체크인 알림', '공항 길찾기'],
  },
];

function App() {
  const [selected, setSelected] = useState('resolved');
  const [phase, setPhase] = useState('capture');
  const [pickedTime, setPickedTime] = useState(null);
  const scenario = useMemo(() => scenarios.find((item) => item.id === selected), [selected]);

  const chooseScenario = (id) => {
    setSelected(id);
    setPickedTime(null);
    setPhase('capture');
  };

  return (
    <main className="shell">
      <nav className="nav">
        <div className="brand"><span className="brand-mark">O</span> OpenLoop</div>
        <span className="nav-copy">Capture → Create → Close</span>
      </nav>

      <section className="hero">
        <p className="kicker">AI ACTION CALENDAR</p>
        <h1>캡처만 하세요.<br /><em>일정은 OpenLoop가 만듭니다.</em></h1>
        <p className="lede">대화와 포스터의 맥락을 이해해 정확한 일정으로 만들고, 끝날 때까지 필요한 순간에 다시 챙깁니다.</p>
      </section>

      <div className="scenario-tabs" aria-label="데모 시나리오">
        {scenarios.map((item) => (
          <button className={selected === item.id ? 'active' : ''} onClick={() => chooseScenario(item.id)} key={item.id}>{item.label}</button>
        ))}
      </div>

      <section className="stage">
        <article className="capture-card">
          <div className="card-top"><span>공유된 캡처</span><span className="privacy">원본은 분석 후 폐기</span></div>
          <div className="messages">
            {scenario.source.map((line, index) => <p className={index % 2 ? 'mine' : ''} key={line}>{line}</p>)}
          </div>
          <button className="capture-button" onClick={() => setPhase('created')}>OpenLoop로 공유 <span>↗</span></button>
        </article>

        <div className="flow-mark" aria-hidden="true">→</div>

        <article className={`result-card ${phase === 'capture' ? 'waiting' : ''}`}>
          {phase === 'capture' ? (
            <div className="empty-state"><div className="orb">O</div><p>캡처를 공유하면<br />맥락을 일정으로 바꿉니다.</p></div>
          ) : phase === 'closed' ? (
            <div className="closed-state"><div className="closed-icon">✓</div><p className="eyebrow">LOOP CLOSED</p><h2>{scenario.title}</h2><p>필요한 행동이 모두 끝났습니다.</p><button className="secondary" onClick={() => setPhase('capture')}>다른 캡처 보기</button></div>
          ) : (
            <>
              <div className="status-row"><span className="eyebrow">{scenario.eyebrow}</span><span className={`confidence ${scenario.confidence < 60 ? 'low' : ''}`}>{scenario.confidence}% 확신</span></div>
              <h2>{scenario.title}</h2>
              <dl><div><dt>WHEN</dt><dd>{pickedTime ? `이번 주 토요일 · ${pickedTime}` : scenario.when}</dd></div><div><dt>WHERE</dt><dd>{scenario.place}</dd></div></dl>
              <p className="reasoning">{scenario.note}</p>
              {scenario.choices && !pickedTime && <div className="choice-block"><b>몇 시로 등록할까요?</b><div>{scenario.choices.map((time) => <button key={time} onClick={() => setPickedTime(time)}>{time}</button>)}</div></div>}
              <div className="action-list">{scenario.actions.map((action) => <span key={action}>✓ {action}</span>)}</div>
              <button className="primary" disabled={scenario.choices && !pickedTime} onClick={() => setPhase('closed')}>{scenario.id === 'deadline' ? 'OpenLoop 생성' : '일정 추가'}</button>
            </>
          )}
        </article>
      </section>

      <footer><p>이해에서 끝내지 않고, 행동과 완료까지.</p><span>Privacy-first · Event-driven · Confidence-aware</span></footer>
    </main>
  );
}

createRoot(document.getElementById('root')).render(<React.StrictMode><App /></React.StrictMode>);
