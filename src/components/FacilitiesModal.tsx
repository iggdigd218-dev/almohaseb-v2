import React, { useState, useEffect } from 'react';
import {
  Building2,
  Plus,
  Check,
  X,
  Phone,
  MapPin,
  TrendingUp,
  Users,
  CreditCard,
  QrCode,
  Copy,
  Edit2,
  Trash2,
  ShieldCheck,
  RefreshCw,
} from 'lucide-react';
import { Facility, CloudInviteData } from '../types';
import { api } from '../api';
import { setActiveFacilityId, getActiveFacilityId } from '../services/syncQueueService';

interface FacilitiesModalProps {
  isOpen: boolean;
  onClose: () => void;
  currentFacilityId?: string;
  onFacilityChanged: (newFacilityId: string) => void;
  onShowToast: (msg: string, type?: 'success' | 'error' | 'info') => void;
}

export const FacilitiesModal: React.FC<FacilitiesModalProps> = ({
  isOpen,
  onClose,
  currentFacilityId = getActiveFacilityId(),
  onFacilityChanged,
  onShowToast,
}) => {
  const [facilities, setFacilities] = useState<Facility[]>([]);
  const [loading, setLoading] = useState(false);
  const [isAdding, setIsAdding] = useState(false);
  const [editingFacility, setEditingFacility] = useState<Facility | null>(null);

  // Form State
  const [formName, setFormName] = useState('');
  const [formActivity, setFormActivity] = useState('');
  const [formPhone, setFormPhone] = useState('');
  const [formAddress, setFormAddress] = useState('');
  const [formCurrency, setFormCurrency] = useState('YER');

  // Instant Cloud Pairing State
  const [pairingData, setPairingData] = useState<CloudInviteData | null>(null);
  const [pairingLoading, setPairingLoading] = useState(false);

  const loadFacilities = async () => {
    setLoading(true);
    try {
      const data = await api.getFacilities();
      setFacilities(data);
    } catch {
      onShowToast('تعذّر تحميل قائمة المنشآت', 'error');
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    if (isOpen) {
      loadFacilities();
      setIsAdding(false);
      setEditingFacility(null);
      setPairingData(null);
    }
  }, [isOpen]);

  if (!isOpen) return null;

  const handleSelectFacility = async (facId: string) => {
    try {
      await api.switchFacility(facId);
      setActiveFacilityId(facId);
      onFacilityChanged(facId);
      onShowToast(
        facId === 'all'
          ? 'تم التبديل إلى عرض جميع المنشآت (تجميعي شامل)'
          : `تم التبديل إلى المنشأة بنجاح`,
        'success'
      );
      onClose();
    } catch {
      onShowToast('فشل التبديل بين المنشآت', 'error');
    }
  };

  const handleSaveFacility = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!formName.trim()) {
      onShowToast('يرجى إدخال اسم المنشأة أو الفرع', 'error');
      return;
    }

    try {
      if (editingFacility) {
        await api.updateFacility(editingFacility.id, {
          name: formName.trim(),
          activity: formActivity.trim(),
          phone: formPhone.trim(),
          address: formAddress.trim(),
          currency: formCurrency,
        });
        onShowToast('تم تحديث بيانات المنشأة بنجاح', 'success');
      } else {
        await api.createFacility({
          name: formName.trim(),
          activity: formActivity.trim(),
          phone: formPhone.trim(),
          address: formAddress.trim(),
          currency: formCurrency,
        });
        onShowToast('تمت إضافة المنشأة الجديدة بنجاح', 'success');
      }
      setIsAdding(false);
      setEditingFacility(null);
      resetForm();
      loadFacilities();
    } catch (err: any) {
      onShowToast(err?.message || 'تعذّر حفظ بيانات المنشأة', 'error');
    }
  };

  const resetForm = () => {
    setFormName('');
    setFormActivity('');
    setFormPhone('');
    setFormAddress('');
    setFormCurrency('YER');
  };

  const handleEditClick = (fac: Facility) => {
    setEditingFacility(fac);
    setFormName(fac.name);
    setFormActivity(fac.activity || '');
    setFormPhone(fac.phone || '');
    setFormAddress(fac.address || '');
    setFormCurrency(fac.currency || 'YER');
    setIsAdding(true);
  };

  const handleDeleteClick = async (fac: Facility) => {
    if (fac.is_default || fac.id === 'WS-MAIN') {
      onShowToast('لا يمكن حذف المنشأة الرئيسية الافتراضية', 'error');
      return;
    }
    if (!confirm(`هل أنت متأكد من حذف فرع «${fac.name}»؟`)) return;

    try {
      await api.deleteFacility(fac.id);
      onShowToast('تم حذف المنشأة بنجاح', 'success');
      if (currentFacilityId === fac.id) {
        handleSelectFacility('WS-MAIN');
      } else {
        loadFacilities();
      }
    } catch (err: any) {
      onShowToast(err?.message || 'فشل حذف المنشأة', 'error');
    }
  };

  const handleGeneratePairingCode = async (facId: string) => {
    setPairingLoading(true);
    try {
      const invite = await api.createCloudInvite(facId);
      setPairingData(invite);
      onShowToast(`تم توليد كود الاقتران الفوري بنجاح (PIN: ${invite.pin})`, 'success');
    } catch {
      onShowToast('تعذّر توليد كود الاقتران', 'error');
    } finally {
      setPairingLoading(false);
    }
  };

  return (
    <div
      className="fixed inset-0 bg-slate-900/60 backdrop-blur-xs flex items-center justify-center p-4 z-50 animate-in fade-in"
      dir="rtl"
    >
      <div className="bg-white rounded-3xl shadow-2xl border border-slate-200 max-w-2xl w-full max-h-[90vh] flex flex-col overflow-hidden">
        {/* Modal Header */}
        <div className="p-5 border-b border-slate-100 flex items-center justify-between bg-slate-50/70">
          <div className="flex items-center gap-3">
            <div className="w-10 h-10 rounded-2xl bg-sky-600 text-white flex items-center justify-center shadow-md shadow-sky-600/20">
              <Building2 className="w-5 h-5" />
            </div>
            <div>
              <h3 className="text-base font-black text-slate-900">
                إدارة المنشآت والفروع المتعددة
              </h3>
              <p className="text-xs text-slate-500 font-medium">
                التبديل بين الفروع، إنشاء منشآت جديدة، وتوليد أكواد الاقتران السحابي
              </p>
            </div>
          </div>
          <button
            onClick={onClose}
            className="w-8 h-8 rounded-full hover:bg-slate-200/80 flex items-center justify-center text-slate-400 hover:text-slate-700 transition-colors"
          >
            <X className="w-5 h-5" />
          </button>
        </div>

        {/* Modal Body */}
        <div className="flex-1 overflow-y-auto p-5 space-y-4">
          {/* Action Bar */}
          <div className="flex items-center justify-between gap-3">
            <button
              onClick={() => handleSelectFacility('all')}
              className={`flex-1 py-2.5 px-3 rounded-xl border text-xs font-bold transition-all flex items-center justify-center gap-2 ${
                currentFacilityId === 'all'
                  ? 'bg-sky-600 text-white border-sky-600 shadow-md shadow-sky-600/20'
                  : 'bg-white text-slate-700 border-slate-200 hover:bg-slate-50'
              }`}
            >
              <span>🌐 جميع المنشآت (تجميعي شامل)</span>
              {currentFacilityId === 'all' && <Check className="w-4 h-4" />}
            </button>

            {!isAdding && (
              <button
                onClick={() => {
                  resetForm();
                  setEditingFacility(null);
                  setIsAdding(true);
                }}
                className="py-2.5 px-4 bg-emerald-600 hover:bg-emerald-700 text-white text-xs font-bold rounded-xl transition-all flex items-center gap-1.5 shadow-sm shadow-emerald-600/20"
              >
                <Plus className="w-4 h-4" />
                <span>إضافة منشأة أو فرع</span>
              </button>
            )}
          </div>

          {/* Instant Pairing Code Banner */}
          {pairingData && (
            <div className="p-4 bg-indigo-50 border border-indigo-200 rounded-2xl space-y-3 animate-in fade-in">
              <div className="flex items-center justify-between">
                <div className="flex items-center gap-2">
                  <ShieldCheck className="w-5 h-5 text-indigo-600" />
                  <span className="text-xs font-black text-indigo-900">
                    كود الاقتران الفوري جاهز ({pairingData.facility_name})
                  </span>
                </div>
                <button
                  onClick={() => setPairingData(null)}
                  className="text-indigo-400 hover:text-indigo-600"
                >
                  <X className="w-4 h-4" />
                </button>
              </div>
              <div className="flex items-center gap-4 bg-white p-3 rounded-xl border border-indigo-100">
                <div className="flex-1 text-center">
                  <p className="text-[11px] text-slate-500 font-bold mb-1">رمز PIN الرقمي (6 أرقام):</p>
                  <span className="font-mono text-2xl font-black text-indigo-700 tracking-widest select-all">
                    {pairingData.pin}
                  </span>
                </div>
                <div className="h-10 w-px bg-slate-200" />
                <div className="flex-1 text-center">
                  <p className="text-[11px] text-slate-500 font-bold mb-1">معرف المنشأة السحابي:</p>
                  <span className="font-mono text-xs font-bold text-slate-700 select-all">
                    {pairingData.facility_id}
                  </span>
                </div>
              </div>
              <p className="text-[11px] text-indigo-700 text-center font-medium">
                ⚡ يمكن لأي جهاز كاشير أو عضو إدخال رمز PIN أعلاه للانضمام فوراً في ثوانٍ معدودة دون تأخير.
              </p>
            </div>
          )}

          {/* Add / Edit Form */}
          {isAdding && (
            <form
              onSubmit={handleSaveFacility}
              className="p-4 bg-slate-50 rounded-2xl border border-slate-200 space-y-3 animate-in fade-in"
            >
              <div className="flex items-center justify-between pb-2 border-b border-slate-200">
                <span className="text-xs font-black text-slate-800">
                  {editingFacility ? 'تعديل بيانات المنشأة' : 'بيانات المنشأة أو الفرع الجديد'}
                </span>
                <button
                  type="button"
                  onClick={() => {
                    setIsAdding(false);
                    setEditingFacility(null);
                  }}
                  className="text-xs text-slate-400 hover:text-slate-600"
                >
                  إلغاء
                </button>
              </div>

              <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
                <div>
                  <label className="block text-[11px] font-bold text-slate-600 mb-1">
                    اسم المنشأة أو الفرع *
                  </label>
                  <input
                    type="text"
                    required
                    value={formName}
                    onChange={(e) => setFormName(e.target.value)}
                    placeholder="مثال: فرع السوبرماركت 2"
                    className="w-full text-xs p-2.5 bg-white border border-slate-200 rounded-xl focus:border-sky-500 focus:outline-none"
                  />
                </div>

                <div>
                  <label className="block text-[11px] font-bold text-slate-600 mb-1">
                    النشاط التجاري
                  </label>
                  <input
                    type="text"
                    value={formActivity}
                    onChange={(e) => setFormActivity(e.target.value)}
                    placeholder="مثال: تجزئة ومواد غذائية"
                    className="w-full text-xs p-2.5 bg-white border border-slate-200 rounded-xl focus:border-sky-500 focus:outline-none"
                  />
                </div>

                <div>
                  <label className="block text-[11px] font-bold text-slate-600 mb-1">
                    رقم الهاتف / الواتساب
                  </label>
                  <input
                    type="text"
                    value={formPhone}
                    onChange={(e) => setFormPhone(e.target.value)}
                    placeholder="777XXXXXX"
                    className="w-full text-xs p-2.5 bg-white border border-slate-200 rounded-xl focus:border-sky-500 focus:outline-none"
                  />
                </div>

                <div>
                  <label className="block text-[11px] font-bold text-slate-600 mb-1">
                    العنوان / الموقع
                  </label>
                  <input
                    type="text"
                    value={formAddress}
                    onChange={(e) => setFormAddress(e.target.value)}
                    placeholder="صنعاء - شارع..."
                    className="w-full text-xs p-2.5 bg-white border border-slate-200 rounded-xl focus:border-sky-500 focus:outline-none"
                  />
                </div>

                <div>
                  <label className="block text-[11px] font-bold text-slate-600 mb-1">
                    العملة الافتراضية للفرع
                  </label>
                  <select
                    value={formCurrency}
                    onChange={(e) => setFormCurrency(e.target.value)}
                    className="w-full text-xs p-2.5 bg-white border border-slate-200 rounded-xl focus:border-sky-500 focus:outline-none"
                  >
                    <option value="YER">ريال يمني (YER)</option>
                    <option value="SAR">ريال سعودي (SAR)</option>
                    <option value="USD">دولار أمريكي (USD)</option>
                  </select>
                </div>
              </div>

              <div className="flex justify-end gap-2 pt-2">
                <button
                  type="button"
                  onClick={() => {
                    setIsAdding(false);
                    setEditingFacility(null);
                  }}
                  className="px-3 py-2 text-xs font-bold text-slate-600 hover:bg-slate-200 rounded-xl transition-colors"
                >
                  إلغاء
                </button>
                <button
                  type="submit"
                  className="px-4 py-2 text-xs font-bold text-white bg-sky-600 hover:bg-sky-700 rounded-xl transition-colors shadow-sm"
                >
                  {editingFacility ? 'حفظ التعديلات' : 'تأكيد إضافة المنشأة'}
                </button>
              </div>
            </form>
          )}

          {/* Facilities List */}
          <div className="space-y-2.5">
            {facilities.map((fac) => {
              const isCurrent = currentFacilityId === fac.id;
              return (
                <div
                  key={fac.id}
                  className={`p-4 rounded-2xl border transition-all ${
                    isCurrent
                      ? 'bg-sky-50/50 border-sky-300 ring-2 ring-sky-500/10'
                      : 'bg-white border-slate-200 hover:border-slate-300'
                  }`}
                >
                  <div className="flex items-start justify-between gap-3">
                    <div className="min-w-0 flex-1">
                      <div className="flex items-center gap-2 flex-wrap">
                        <h4 className="text-sm font-black text-slate-900">{fac.name}</h4>
                        {fac.is_default === 1 && (
                          <span className="px-2 py-0.5 rounded-full text-[10px] font-black bg-amber-100 text-amber-800 border border-amber-200">
                            الفرع الرئيسي
                          </span>
                        )}
                        <span className="px-2 py-0.5 rounded-full text-[10px] font-mono font-bold bg-slate-100 text-slate-600">
                          {fac.id}
                        </span>
                      </div>

                      {fac.activity && (
                        <p className="text-xs text-slate-500 font-medium mt-1">
                          {fac.activity}
                        </p>
                      )}

                      <div className="flex items-center gap-4 text-xs text-slate-500 mt-2 flex-wrap">
                        {fac.phone && (
                          <span className="flex items-center gap-1">
                            <Phone className="w-3.5 h-3.5 text-slate-400" />
                            {fac.phone}
                          </span>
                        )}
                        {fac.address && (
                          <span className="flex items-center gap-1">
                            <MapPin className="w-3.5 h-3.5 text-slate-400" />
                            {fac.address}
                          </span>
                        )}
                        <span className="flex items-center gap-1 font-bold text-slate-700">
                          العملة: {fac.currency}
                        </span>
                      </div>

                      {/* Branch Metrics */}
                      <div className="flex items-center gap-3 mt-3 pt-2.5 border-t border-slate-100 text-[11px] text-slate-600 font-bold flex-wrap">
                        <span className="flex items-center gap-1">
                          <Users className="w-3.5 h-3.5 text-sky-500" />
                          الحسابات: {fac.accounts_count ?? 0}
                        </span>
                        <span className="flex items-center gap-1">
                          <CreditCard className="w-3.5 h-3.5 text-indigo-500" />
                          العمليات: {fac.transactions_count ?? 0}
                        </span>
                        <span className="flex items-center gap-1">
                          <TrendingUp className="w-3.5 h-3.5 text-emerald-500" />
                          المبيعات: {(fac.total_sales ?? 0).toLocaleString()} {fac.currency}
                        </span>
                      </div>
                    </div>

                    {/* Actions */}
                    <div className="flex flex-col items-end gap-2 shrink-0">
                      {isCurrent ? (
                        <span className="px-3 py-1.5 rounded-xl bg-sky-600 text-white text-xs font-black flex items-center gap-1.5 shadow-sm">
                          <Check className="w-3.5 h-3.5" />
                          الفرع النشط حالياً
                        </span>
                      ) : (
                        <button
                          onClick={() => handleSelectFacility(fac.id)}
                          className="px-3 py-1.5 rounded-xl bg-slate-900 hover:bg-slate-800 text-white text-xs font-bold transition-colors"
                        >
                          التبديل لهذا الفرع
                        </button>
                      )}

                      <div className="flex items-center gap-1 mt-1">
                        <button
                          onClick={() => handleGeneratePairingCode(fac.id)}
                          className="p-1.5 text-indigo-600 hover:bg-indigo-50 rounded-lg transition-colors"
                          title="توليد كود اقتران فوري (QR/PIN) لأجهزة هذا الفرع"
                        >
                          <QrCode className="w-4 h-4" />
                        </button>
                        <button
                          onClick={() => handleEditClick(fac)}
                          className="p-1.5 text-slate-600 hover:bg-slate-100 rounded-lg transition-colors"
                          title="تعديل بيانات الفرع"
                        >
                          <Edit2 className="w-4 h-4" />
                        </button>
                        {fac.is_default !== 1 && fac.id !== 'WS-MAIN' && (
                          <button
                            onClick={() => handleDeleteClick(fac)}
                            className="p-1.5 text-rose-500 hover:bg-rose-50 rounded-lg transition-colors"
                            title="حذف هذا الفرع"
                          >
                            <Trash2 className="w-4 h-4" />
                          </button>
                        )}
                      </div>
                    </div>
                  </div>
                </div>
              );
            })}
          </div>
        </div>

        {/* Modal Footer */}
        <div className="p-4 border-t border-slate-100 bg-slate-50 flex items-center justify-between text-xs text-slate-500">
          <span>نظام نكسورا المحاسبي — متعدد المنشآت والمستخدمين والحسابات</span>
          <button
            onClick={onClose}
            className="px-4 py-2 bg-slate-200 hover:bg-slate-300 text-slate-700 font-bold rounded-xl transition-colors"
          >
            إغلاق
          </button>
        </div>
      </div>
    </div>
  );
};
