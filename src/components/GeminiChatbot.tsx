import React, { useState, useRef, useEffect } from 'react';
import {
  Bot,
  Send,
  Sparkles,
  Trash2,
  X,
  Zap,
  Brain,
  Cpu,
  Calculator,
  MessageSquareWarning,
  PackageSearch,
  ChevronDown,
} from 'lucide-react';

export interface ChatTurn {
  id: string;
  role: 'user' | 'model';
  text: string;
  timestamp: string;
  modelUsed?: string;
}

interface GeminiChatbotProps {
  mode?: 'screen' | 'floating';
  onShowToast?: (msg: string, type?: 'success' | 'error' | 'info') => void;
}

const ROLES = [
  {
    id: 'accountant',
    label: 'المحاسب المالي الذكي',
    icon: Calculator,
    desc: 'تحليل المبيعات والديون والأرصدة والقيود المحاسبية',
    systemPrompt:
      'أنت «روبوت المحاسب الذكي» في تطبيق «المحاسب». دورك هو محاسب مالي قانوني وخبير في إدارة المبيعات والديون والقيود المحاسبية وسندات القبض والصرف. قدّم إجابات دقيقة ومنظمة باللغة العربية مع أرقام واضحة ونصائح عملية لتحسين التدفق النقدي.',
  },
  {
    id: 'collector',
    label: 'مستشار تحصيل الديون',
    icon: MessageSquareWarning,
    desc: 'صياغة رسائل مطالبة وجدولة مديونيات العملاء باحترافية',
    systemPrompt:
      'أنت «مستشار تحصيل الديون الذكي» في تطبيق «المحاسب». دورك هو مساعدة التاجر أو المدير في متابعة ديون العملاء، جدولة السداد، وصياغة رسائل مطالبة وتذكير احترافية ولَبِقة عبر واتساب أو الرسائل النصية لتحصيل المستحقات بسرعة دون خسارة العملاء.',
  },
  {
    id: 'inventory',
    label: 'خبير المخزون والمشتريات',
    icon: PackageSearch,
    desc: 'تحليل النواقص وحركة الأصناف وهوامش الربح',
    systemPrompt:
      'أنت «خبير المخزون والمشتريات الذكي» في تطبيق «المحاسب». دورك هو تحليل حركة الأصناف، تنبيه المدير للأصناف التي أوشكت على النفاد، واقتراح كميات إعادة الطلب وهوامش الربح المناسبة.',
  },
] as const;

const MODELS = [
  {
    id: 'gemini-3.8-flash',
    label: 'متوازن (Flash)',
    sub: 'للمهام المحاسبية العامة',
    icon: Sparkles,
  },
  {
    id: 'gemini-3.1-flash-lite',
    label: 'سريع (Flash Lite)',
    sub: 'للردود الفورية السريعة',
    icon: Zap,
  },
  {
    id: 'gemini-3.1-pro-preview',
    label: 'معمّق (Pro)',
    sub: 'للتحليل المالي المعقّد',
    icon: Brain,
  },
] as const;

const QUICK_PROMPTS = [
  'لخّص الوضع المالي للمنشأة وأهم المؤشرات اليوم',
  'من هم أعلى العملاء مديونية وكيف نجدول تحصيلهم؟',
  'اكتب رسالة واتساب لبقة لتذكير عميل بسداد فاتورته المستحقة',
  'ما هي الأصناف التي أوشكت على النفاد في المخزون؟',
];

const STORAGE_KEY = 'almohaseb_gemini_chat_history_v1';

export const GeminiChatbot: React.FC<GeminiChatbotProps> = ({
  mode = 'screen',
  onShowToast,
}) => {
  const [isOpen, setIsOpen] = useState(false);
  const [selectedRole, setSelectedRole] = useState<string>('accountant');
  const [selectedModel, setSelectedModel] = useState<string>('gemini-3.8-flash');
  const [customInstruction, setCustomInstruction] = useState<string>('');
  const [showRoleConfig, setShowRoleConfig] = useState(false);
  const [input, setInput] = useState('');
  const [isSending, setIsSending] = useState(false);
  const [messages, setMessages] = useState<ChatTurn[]>(() => {
    try {
      const saved = localStorage.getItem(STORAGE_KEY);
      if (saved) {
        const parsed = JSON.parse(saved);
        if (Array.isArray(parsed) && parsed.length > 0) return parsed;
      }
    } catch {}
    return [
      {
        id: 'welcome-1',
        role: 'model',
        text: 'مرحباً بك في **روبوت المحاسب الذكي (Gemini)**! 🤖📊\n\nيمكنني مساعدتك في تحليل المبيعات والديون، مراجعة أرصدة العملاء، فحص نواقص المخزون، أو صياغة رسائل تحصيل احترافية. كيف يمكنني مساعدتك اليوم؟',
        timestamp: new Date().toLocaleTimeString('ar-YE', {
          hour: '2-digit',
          minute: '2-digit',
        }),
        modelUsed: 'gemini-3.8-flash',
      },
    ];
  });

  const scrollRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(messages.slice(-40)));
    } catch {}
    if (scrollRef.current) {
      scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
    }
  }, [messages, isOpen]);

  const sendMessage = async (textToSend?: string) => {
    const trimmed = (textToSend ?? input).trim();
    if (!trimmed || isSending) return;

    const userTurn: ChatTurn = {
      id: 'u-' + Date.now(),
      role: 'user',
      text: trimmed,
      timestamp: new Date().toLocaleTimeString('ar-YE', {
        hour: '2-digit',
        minute: '2-digit',
      }),
    };

    const nextHistory = [...messages, userTurn];
    setMessages(nextHistory);
    if (!textToSend) setInput('');
    setIsSending(true);

    try {
      const historyPayload = messages
        .filter((m) => m.id !== 'welcome-1')
        .slice(-16)
        .map((m) => ({ role: m.role, text: m.text }));

      const res = await fetch('/api/gemini/chat', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          message: trimmed,
          history: historyPayload,
          role: selectedRole,
          model: selectedModel,
          customSystemInstruction: customInstruction.trim() || undefined,
        }),
      });

      const data = await res.json();
      if (!res.ok) {
        throw new Error(data.error || 'تعذّر الحصول على رد من المساعد الذكي.');
      }

      const botTurn: ChatTurn = {
        id: 'm-' + Date.now(),
        role: 'model',
        text: data.reply || 'تم التحليل بنجاح.',
        timestamp: new Date().toLocaleTimeString('ar-YE', {
          hour: '2-digit',
          minute: '2-digit',
        }),
        modelUsed: data.modelUsed || selectedModel,
      };
      setMessages((prev) => [...prev, botTurn]);
    } catch (err: any) {
      const errMsg = err?.message || 'حدث خطأ أثناء الاتصال بالمساعد الذكي.';
      setMessages((prev) => [
        ...prev,
        {
          id: 'err-' + Date.now(),
          role: 'model',
          text: `⚠️ ${errMsg}`,
          timestamp: new Date().toLocaleTimeString('ar-YE', {
            hour: '2-digit',
            minute: '2-digit',
          }),
        },
      ]);
      onShowToast?.(errMsg, 'error');
    } finally {
      setIsSending(false);
    }
  };

  const clearHistory = () => {
    const reset: ChatTurn[] = [
      {
        id: 'welcome-1',
        role: 'model',
        text: 'تم مسح سجل المحادثة. أنا جاهز لبدء جلسة محاسبية جديدة معك! 📊',
        timestamp: new Date().toLocaleTimeString('ar-YE', {
          hour: '2-digit',
          minute: '2-digit',
        }),
        modelUsed: selectedModel,
      },
    ];
    setMessages(reset);
    localStorage.removeItem(STORAGE_KEY);
    onShowToast?.('تم مسح سجل المحادثة', 'info');
  };

  const currentRoleObj =
    ROLES.find((r) => r.id === selectedRole) || ROLES[0];

  const renderChatPanel = (isModal: boolean) => (
    <div
      className={`flex flex-col bg-white border border-slate-200 shadow-xl overflow-hidden ${
        isModal
          ? 'w-full max-w-lg h-[82vh] max-h-[680px] rounded-3xl'
          : 'w-full h-[calc(100vh-8.5rem)] min-h-[540px] rounded-3xl'
      }`}
      dir="rtl"
    >
      {/* Top Header */}
      <div className="bg-gradient-to-l from-emerald-950 via-emerald-900 to-teal-900 text-white p-4 border-b border-emerald-800/60">
        <div className="flex items-center justify-between gap-2">
          <div className="flex items-center gap-3">
            <div className="w-11 h-11 rounded-2xl bg-amber-400/20 border border-amber-300/40 flex items-center justify-center shadow-inner">
              <Bot className="w-6 h-6 text-amber-300" />
            </div>
            <div>
              <div className="flex items-center gap-2">
                <h3 className="font-black text-sm sm:text-base text-white">
                  روبوت المحاسب الذكي (Gemini)
                </h3>
                <span className="px-2 py-0.5 text-[10px] font-bold rounded-full bg-amber-400/20 text-amber-200 border border-amber-300/30">
                  {currentRoleObj.label}
                </span>
              </div>
              <p className="text-[11px] text-emerald-200/90 mt-0.5">
                {currentRoleObj.desc}
              </p>
            </div>
          </div>

          <div className="flex items-center gap-1.5">
            <button
              type="button"
              onClick={() => setShowRoleConfig(!showRoleConfig)}
              className="flex items-center gap-1 px-2.5 py-1.5 rounded-xl bg-white/10 hover:bg-white/20 text-xs font-bold text-white transition-colors"
              title="تخصيص الدور والنموذج"
            >
              <Cpu className="w-3.5 h-3.5 text-amber-300" />
              <span className="hidden sm:inline">الدور والنموذج</span>
              <ChevronDown className="w-3.5 h-3.5" />
            </button>
            <button
              type="button"
              onClick={clearHistory}
              className="p-2 rounded-xl bg-white/10 hover:bg-rose-500/30 text-emerald-100 hover:text-white transition-colors"
              title="مسح سجل المحادثة"
            >
              <Trash2 className="w-4 h-4" />
            </button>
            {isModal && (
              <button
                type="button"
                onClick={() => setIsOpen(false)}
                className="p-2 rounded-xl bg-white/10 hover:bg-white/20 text-white transition-colors"
                title="إغلاق"
              >
                <X className="w-4 h-4" />
              </button>
            )}
          </div>
        </div>

        {/* Role & Model Selector Bar */}
        {showRoleConfig && (
          <div className="mt-3 pt-3 border-t border-emerald-800/80 space-y-3 text-xs animate-in fade-in">
            <div>
              <div className="text-[11px] font-bold text-emerald-200 mb-1.5">
                1. اختر دور الروبوت (System Role):
              </div>
              <div className="grid grid-cols-1 sm:grid-cols-3 gap-1.5">
                {ROLES.map((r) => {
                  const Icon = r.icon;
                  const active = selectedRole === r.id;
                  return (
                    <button
                      key={r.id}
                      type="button"
                      onClick={() => setSelectedRole(r.id)}
                      className={`flex items-center gap-2 p-2 rounded-xl border text-right transition-all ${
                        active
                          ? 'bg-amber-400 text-slate-950 border-amber-300 font-black shadow-sm'
                          : 'bg-emerald-950/60 text-emerald-100 border-emerald-800 hover:bg-emerald-900'
                      }`}
                    >
                      <Icon className="w-4 h-4 shrink-0" />
                      <div className="truncate">
                        <div className="truncate text-[11px]">{r.label}</div>
                      </div>
                    </button>
                  );
                })}
              </div>
            </div>

            <div>
              <div className="text-[11px] font-bold text-emerald-200 mb-1.5">
                2. اختر نموذج الذكاء الاصطناعي حسب نوع المهمة:
              </div>
              <div className="grid grid-cols-3 gap-1.5">
                {MODELS.map((m) => {
                  const Icon = m.icon;
                  const active = selectedModel === m.id;
                  return (
                    <button
                      key={m.id}
                      type="button"
                      onClick={() => setSelectedModel(m.id)}
                      className={`flex flex-col items-start p-2 rounded-xl border text-right transition-all ${
                        active
                          ? 'bg-sky-400 text-slate-950 border-sky-300 font-black'
                          : 'bg-emerald-950/60 text-emerald-100 border-emerald-800 hover:bg-emerald-900'
                      }`}
                    >
                      <div className="flex items-center gap-1 text-[11px]">
                        <Icon className="w-3.5 h-3.5 shrink-0" />
                        <span>{m.label}</span>
                      </div>
                      <span
                        className={`text-[9.5px] mt-0.5 ${
                          active ? 'text-slate-800' : 'text-emerald-300/80'
                        }`}
                      >
                        {m.sub}
                      </span>
                    </button>
                  );
                })}
              </div>
            </div>

            <div>
              <label className="block text-[11px] font-bold text-emerald-200 mb-1">
                توجيه إضافي خاص للروبوت (System Instruction اختياري):
              </label>
              <input
                type="text"
                value={customInstruction}
                onChange={(e) => setCustomInstruction(e.target.value)}
                placeholder={currentRoleObj.systemPrompt}
                className="w-full px-3 py-1.5 rounded-xl bg-emerald-950/80 border border-emerald-700 text-white placeholder-emerald-400/60 text-xs focus:outline-none focus:border-amber-400"
              />
            </div>
          </div>
        )}
      </div>

      {/* Quick Prompts Bar */}
      <div className="px-3 py-2 bg-slate-50 border-b border-slate-200 flex items-center gap-1.5 overflow-x-auto no-scrollbar">
        <span className="text-[10px] font-bold text-slate-400 shrink-0 pl-1">
          اقتراحات سريعة:
        </span>
        {QUICK_PROMPTS.map((q, idx) => (
          <button
            key={idx}
            type="button"
            disabled={isSending}
            onClick={() => sendMessage(q)}
            className="shrink-0 px-2.5 py-1 rounded-full bg-white hover:bg-emerald-50 text-slate-700 hover:text-emerald-800 border border-slate-200 hover:border-emerald-300 text-[11px] font-semibold transition-colors"
          >
            {q}
          </button>
        ))}
      </div>

      {/* Scrollable Message Thread */}
      <div
        ref={scrollRef}
        className="flex-1 overflow-y-auto p-4 space-y-3 bg-slate-50/60"
      >
        {messages.map((msg) => {
          const isUser = msg.role === 'user';
          return (
            <div
              key={msg.id}
              className={`flex ${isUser ? 'justify-start' : 'justify-end'}`}
            >
              <div
                className={`max-w-[85%] rounded-2xl px-4 py-3 text-xs leading-relaxed shadow-xs ${
                  isUser
                    ? 'bg-emerald-700 text-white rounded-tr-xs'
                    : 'bg-white text-slate-800 border border-slate-200 rounded-tl-xs'
                }`}
              >
                <div className="whitespace-pre-wrap break-words">{msg.text}</div>
                <div
                  className={`flex items-center justify-between gap-3 mt-1.5 pt-1 border-t text-[10px] ${
                    isUser
                      ? 'border-emerald-600/60 text-emerald-200'
                      : 'border-slate-100 text-slate-400'
                  }`}
                >
                  <span>{isUser ? 'أنت' : 'روبوت المحاسب'}</span>
                  <div className="flex items-center gap-1.5">
                    {!isUser && msg.modelUsed && (
                      <span className="font-mono text-[9px] px-1.5 py-0.2 rounded bg-slate-100 text-slate-500">
                        {msg.modelUsed}
                      </span>
                    )}
                    <span>{msg.timestamp}</span>
                  </div>
                </div>
              </div>
            </div>
          );
        })}

        {isSending && (
          <div className="flex justify-end">
            <div className="bg-white border border-slate-200 rounded-2xl px-4 py-3 text-xs text-slate-600 flex items-center gap-2 shadow-xs">
              <Sparkles className="w-4 h-4 text-emerald-600 animate-spin" />
              <span>جاري التفكير والتحليل المحاسبي...</span>
            </div>
          </div>
        )}
      </div>

      {/* Input Form */}
      <form
        onSubmit={(e) => {
          e.preventDefault();
          sendMessage();
        }}
        className="p-3 bg-white border-t border-slate-200 flex items-center gap-2"
      >
        <input
          type="text"
          value={input}
          onChange={(e) => setInput(e.target.value)}
          placeholder="اسأل روبوت المحاسب عن المبيعات، الديون، الأصناف، أو اطلب كتابة رسالة مطالبة..."
          className="flex-1 px-4 py-2.5 rounded-2xl bg-slate-100 border border-slate-200 text-xs text-slate-900 placeholder-slate-400 focus:outline-none focus:bg-white focus:border-emerald-600 transition-colors"
        />
        <button
          type="submit"
          disabled={!input.trim() || isSending}
          className="px-4 py-2.5 rounded-2xl bg-emerald-700 hover:bg-emerald-800 disabled:opacity-40 text-white font-bold text-xs flex items-center gap-1.5 shadow-sm transition-all cursor-pointer"
        >
          <Send className="w-4 h-4" />
          <span>إرسال</span>
        </button>
      </form>
    </div>
  );

  if (mode === 'screen') {
    return renderChatPanel(false);
  }

  return (
    <>
      {/* Floating Robot Trigger Button */}
      <button
        type="button"
        onClick={() => setIsOpen(true)}
        className="fixed bottom-20 md:bottom-6 left-5 z-40 flex items-center gap-2 px-4 py-3 rounded-full bg-gradient-to-tr from-emerald-900 via-emerald-700 to-teal-600 text-white font-black text-xs shadow-2xl border-2 border-amber-300/80 hover:scale-105 active:scale-95 transition-all cursor-pointer"
        title="فتح روبوت المحاسب الذكي (Gemini)"
      >
        <Bot className="w-5 h-5 text-amber-300" />
        <span>روبوت المحاسب</span>
      </button>

      {isOpen && (
        <div className="fixed inset-0 z-50 bg-slate-950/60 backdrop-blur-xs flex items-end sm:items-center justify-center p-2 sm:p-4 animate-in fade-in">
          {renderChatPanel(true)}
        </div>
      )}
    </>
  );
};
