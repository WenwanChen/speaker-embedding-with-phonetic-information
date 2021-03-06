#!/bin/bash
# Copyright      2017   David Snyder
#                2017   Johns Hopkins University (Author: Daniel Garcia-Romero)
#                2017   Johns Hopkins University (Author: Daniel Povey)
# Apache 2.0.
#
# See README.txt for more info on data required.
# Results (mostly EERs) are inline in comments below.
#
# This example demonstrates a "bare bones" NIST SRE 2016 recipe using xvectors.
# In the future, we will add score-normalization and a more effective form of
# PLDA domain adaptation.
#
# Pretrained models are available for this recipe.
# See http://kaldi-asr.org/models.html and
# https://david-ryan-snyder.github.io/2017/10/04/model_sre16_v2.html
# for details.

. ./cmd.sh
. ./path.sh
set -e

fea_nj=32
nnet_nj=32

root=/mnt/lv10/person/liuyi/sre.full/
data=$root/data
exp=$root/exp
mfccdir=$root/mfcc
vaddir=$root/mfcc
nnet_dir=$exp/xvector_nnet_1a

data_root=/mnt/lv10/person/liuyi/ly_list/sre16_kaldi_list/
sre16_trials=/mnt/lv10/person/liuyi/sre16/data/sre16_eval_test/trials
sre16_trials_tgl=/mnt/lv10/person/liuyi/sre16/data/sre16_eval_test/trials_tgl
sre16_trials_yue=/mnt/lv10/person/liuyi/sre16/data/sre16_eval_test/trials_yue

stage=0

if [ $stage -le 0 ]; then
  rm -rf $data/sre16_major && cp -r $data_root/sre16_major $data/sre16_major
  rm -rf $data/sre16_minor && cp -r $data_root/sre16_minor $data/sre16_minor
  rm -rf $data/sre16_eval_enroll && cp -r $data_root/sre16_eval_enroll $data/sre16_eval_enroll
  rm -rf $data/sre16_eval_test && cp -r $data_root/sre16_eval_test $data/sre16_eval_test
  
  # Make filterbanks and compute the energy-based VAD for each dataset
  for name in sre16_major sre16_minor sre16_eval_enroll sre16_eval_test; do
    steps/make_mfcc.sh --write-utt2num-frames true --mfcc-config conf/mfcc.conf --nj $fea_nj --cmd "$train_cmd" \
      $data/$name $exp/make_mfcc $mfccdir
    utils/fix_data_dir.sh $data/$name
    sid/compute_vad_decision.sh --nj $fea_nj --cmd "$train_cmd" \
      $data/$name $exp/make_vad $vaddir
    utils/fix_data_dir.sh $data/$name
  done
fi

if [ $stage -le 1 ]; then
  sid/nnet3/xvector/extract_xvectors_new.sh --cmd "$train_cmd" --use-gpu false --nj $nnet_nj \
    $nnet_dir "tdnn6.affine" $data/sre16_major \
    $exp/xvectors_sre16_major
  
  sid/nnet3/xvector/extract_xvectors_new.sh --cmd "$train_cmd" --use-gpu false --nj $nnet_nj \
    $nnet_dir "tdnn6.affine" $data/sre16_minor \
    $exp/xvectors_sre16_minor
  
  sid/nnet3/xvector/extract_xvectors_new.sh --cmd "$train_cmd" --use-gpu false --nj $nnet_nj \
    $nnet_dir "tdnn6.affine" $data/sre16_eval_enroll \
    $exp/xvectors_sre16_eval_enroll
  
  sid/nnet3/xvector/extract_xvectors_new.sh --cmd "$train_cmd" --use-gpu false --nj $nnet_nj \
    $nnet_dir "tdnn6.affine" $data/sre16_eval_test \
    $exp/xvectors_sre16_eval_test
fi

if [ $stage -le 2 ]; then
  lda_dim=150
  
  $train_cmd $exp/xvectors_sre16_major/log/compute_mean.log \
    ivector-mean scp:$exp/xvectors_sre16_major/xvector_sre16_major.scp \
    $exp/xvectors_sre16_major/mean.vec || exit 1;
  
  # This script uses LDA to decrease the dimensionality prior to PLDA.
  $train_cmd $exp/xvectors_sre_combined/log/lda.log \
    ivector-compute-lda --total-covariance-factor=0.0 --dim=$lda_dim \
    "ark:ivector-subtract-global-mean scp:$exp/xvectors_sre_combined/xvector_sre_combined.scp ark:- |" \
    ark:$data/sre_combined/utt2spk $exp/xvectors_sre_combined/transform.mat || exit 1;
  
  # Train an out-of-domain PLDA model.
  $train_cmd $exp/xvectors_sre_combined/log/plda_lda${lda_dim}.log \
    ivector-compute-plda ark:$data/sre_combined/spk2utt \
    "ark:ivector-subtract-global-mean scp:$exp/xvectors_sre_combined/xvector_sre_combined.scp ark:- | transform-vec $exp/xvectors_sre_combined/transform.mat ark:- ark:- | ivector-normalize-length ark:-  ark:- |" \
    $exp/xvectors_sre_combined/plda_lda${lda_dim} || exit 1;
  
  # Here we adapt the out-of-domain PLDA model to SRE16 major, a pile
  # of unlabeled in-domain data.  In the future, we will include a clustering
  # based approach for domain adaptation, which tends to work better.
  $train_cmd $exp/xvectors_sre16_major/log/plda_lda${lda_dim}_sre16_adapt.log \
    ivector-adapt-plda --within-covar-scale=0.75 --between-covar-scale=0.25 \
    $exp/xvectors_sre_combined/plda_lda${lda_dim} \
    "ark:ivector-subtract-global-mean scp:$exp/xvectors_sre16_major/xvector_sre16_major.scp ark:- | transform-vec $exp/xvectors_sre_combined/transform.mat ark:- ark:- | ivector-normalize-length ark:- ark:- |" \
    $exp/xvectors_sre16_major/plda_lda${lda_dim}_sre16_adapt || exit 1;
  
  # Get results using the out-of-domain PLDA model.
  $train_cmd $exp/xvector_scores/log/sre16_eval.log \
    ivector-plda-scoring --normalize-length=true \
    --num-utts=ark:$exp/xvectors_sre16_eval_enroll/num_utts.ark \
    "ivector-copy-plda --smoothing=0.0 $exp/xvectors_sre_combined/plda_lda${lda_dim} - |" \
    "ark:ivector-mean ark:$data/sre16_eval_enroll/spk2utt scp:$exp/xvectors_sre16_eval_enroll/xvector_sre16_eval_enroll.scp ark:- | ivector-subtract-global-mean $exp/xvectors_sre16_major/mean.vec ark:- ark:- | transform-vec $exp/xvectors_sre_combined/transform.mat ark:- ark:- | ivector-normalize-length ark:- ark:- |" \
    "ark:ivector-subtract-global-mean $exp/xvectors_sre16_major/mean.vec scp:$exp/xvectors_sre16_eval_test/xvector_sre16_eval_test.scp ark:- | transform-vec $exp/xvectors_sre_combined/transform.mat ark:- ark:- | ivector-normalize-length ark:- ark:- |" \
    "cat '$sre16_trials' | cut -d\  --fields=1,2 |" $exp/xvector_scores/sre16_eval_scores || exit 1;
  
  utils/filter_scp.pl $sre16_trials_tgl $exp/xvector_scores/sre16_eval_scores > $exp/xvector_scores/sre16_eval_tgl_scores
  utils/filter_scp.pl $sre16_trials_yue $exp/xvector_scores/sre16_eval_scores > $exp/xvector_scores/sre16_eval_yue_scores
  pooled_eer=$(paste $sre16_trials $exp/xvector_scores/sre16_eval_scores | awk '{print $6, $3}' | compute-eer - 2>/dev/null)
  tgl_eer=$(paste $sre16_trials_tgl $exp/xvector_scores/sre16_eval_tgl_scores | awk '{print $6, $3}' | compute-eer - 2>/dev/null)
  yue_eer=$(paste $sre16_trials_yue $exp/xvector_scores/sre16_eval_yue_scores | awk '{print $6, $3}' | compute-eer - 2>/dev/null)
  echo "Using Out-of-Domain PLDA, EER: Pooled ${pooled_eer}%, Tagalog ${tgl_eer}%, Cantonese ${yue_eer}%"
  
  paste $sre16_trials $exp/xvector_scores/sre16_eval_scores | awk '{print $6, $3}' > $exp/xvector_scores/sre16_eval_scores.new
  grep ' target$' $exp/xvector_scores/sre16_eval_scores.new | cut -d ' ' -f 1 > $exp/xvector_scores/sre16_eval_scores.target
  grep ' nontarget$' $exp/xvector_scores/sre16_eval_scores.new | cut -d ' ' -f 1 > $exp/xvector_scores/sre16_eval_scores.nontarget
  cd ${KALDI_ROOT}/tools/det_score
  comm=`echo "get_eer('$exp/xvector_scores/sre16_eval_scores.target', '$exp/xvector_scores/sre16_eval_scores.nontarget', '$exp/xvector_scores/sre16_eval_scores.result')"`
  echo "$comm"| matlab -nodesktop -noFigureWindows > /dev/null
  cd -
  rm -f $exp/xvector_scores/sre16_eval_scores.new $exp/xvector_scores/sre16_eval_scores.target $exp/xvector_scores/sre16_eval_scores.nontarget
  tail -n 1 $exp/xvector_scores/sre16_eval_scores.result
  
  paste $sre16_trials_tgl $exp/xvector_scores/sre16_eval_tgl_scores | awk '{print $6, $3}' > $exp/xvector_scores/sre16_eval_tgl_scores.new
  grep ' target$' $exp/xvector_scores/sre16_eval_tgl_scores.new | cut -d ' ' -f 1 > $exp/xvector_scores/sre16_eval_tgl_scores.target
  grep ' nontarget$' $exp/xvector_scores/sre16_eval_tgl_scores.new | cut -d ' ' -f 1 > $exp/xvector_scores/sre16_eval_tgl_scores.nontarget
  cd ${KALDI_ROOT}/tools/det_score
  comm=`echo "get_eer('$exp/xvector_scores/sre16_eval_tgl_scores.target', '$exp/xvector_scores/sre16_eval_tgl_scores.nontarget', '$exp/xvector_scores/sre16_eval_tgl_scores.result')"`
  echo "$comm"| matlab -nodesktop -noFigureWindows > /dev/null
  cd -
  rm -f $exp/xvector_scores/sre16_eval_tgl_scores.new $exp/xvector_scores/sre16_eval_tgl_scores.target $exp/xvector_scores/sre16_eval_tgl_scores.nontarget
  tail -n 1 $exp/xvector_scores/sre16_eval_tgl_scores.result
  
  paste $sre16_trials_yue $exp/xvector_scores/sre16_eval_yue_scores | awk '{print $6, $3}' > $exp/xvector_scores/sre16_eval_yue_scores.new
  grep ' target$' $exp/xvector_scores/sre16_eval_yue_scores.new | cut -d ' ' -f 1 > $exp/xvector_scores/sre16_eval_yue_scores.target
  grep ' nontarget$' $exp/xvector_scores/sre16_eval_yue_scores.new | cut -d ' ' -f 1 > $exp/xvector_scores/sre16_eval_yue_scores.nontarget
  cd ${KALDI_ROOT}/tools/det_score
  comm=`echo "get_eer('$exp/xvector_scores/sre16_eval_yue_scores.target', '$exp/xvector_scores/sre16_eval_yue_scores.nontarget', '$exp/xvector_scores/sre16_eval_yue_scores.result')"`
  echo "$comm"| matlab -nodesktop -noFigureWindows > /dev/null
  cd -
  rm -f $exp/xvector_scores/sre16_eval_yue_scores.new $exp/xvector_scores/sre16_eval_yue_scores.target $exp/xvector_scores/sre16_eval_yue_scores.nontarget
  tail -n 1 $exp/xvector_scores/sre16_eval_yue_scores.result
  
  # Get results using the adapted PLDA model.
  $train_cmd $exp/xvector_scores/log/sre16_eval_scoring_adapt.log \
    ivector-plda-scoring --normalize-length=true \
    --num-utts=ark:$exp/xvectors_sre16_eval_enroll/num_utts.ark \
    "ivector-copy-plda --smoothing=0.0 $exp/xvectors_sre16_major/plda_lda${lda_dim}_sre16_adapt - |" \
    "ark:ivector-mean ark:$data/sre16_eval_enroll/spk2utt scp:$exp/xvectors_sre16_eval_enroll/xvector_sre16_eval_enroll.scp ark:- | ivector-subtract-global-mean $exp/xvectors_sre16_major/mean.vec ark:- ark:- | transform-vec $exp/xvectors_sre_combined/transform.mat ark:- ark:- | ivector-normalize-length ark:- ark:- |" \
    "ark:ivector-subtract-global-mean $exp/xvectors_sre16_major/mean.vec scp:$exp/xvectors_sre16_eval_test/xvector_sre16_eval_test.scp ark:- | transform-vec $exp/xvectors_sre_combined/transform.mat ark:- ark:- | ivector-normalize-length ark:- ark:- |" \
    "cat '$sre16_trials' | cut -d\  --fields=1,2 |" $exp/xvector_scores/sre16_eval_scores_adapt || exit 1;
  
  utils/filter_scp.pl $sre16_trials_tgl $exp/xvector_scores/sre16_eval_scores_adapt > $exp/xvector_scores/sre16_eval_tgl_scores_adapt
  utils/filter_scp.pl $sre16_trials_yue $exp/xvector_scores/sre16_eval_scores_adapt > $exp/xvector_scores/sre16_eval_yue_scores_adapt
  pooled_eer=$(paste $sre16_trials $exp/xvector_scores/sre16_eval_scores_adapt | awk '{print $6, $3}' | compute-eer - 2>/dev/null)
  tgl_eer=$(paste $sre16_trials_tgl $exp/xvector_scores/sre16_eval_tgl_scores_adapt | awk '{print $6, $3}' | compute-eer - 2>/dev/null)
  yue_eer=$(paste $sre16_trials_yue $exp/xvector_scores/sre16_eval_yue_scores_adapt | awk '{print $6, $3}' | compute-eer - 2>/dev/null)
  echo "Using Adapted PLDA, EER: Pooled ${pooled_eer}%, Tagalog ${tgl_eer}%, Cantonese ${yue_eer}%"
  
  paste $sre16_trials $exp/xvector_scores/sre16_eval_scores_adapt | awk '{print $6, $3}' > $exp/xvector_scores/sre16_eval_scores_adapt.new
  grep ' target$' $exp/xvector_scores/sre16_eval_scores_adapt.new | cut -d ' ' -f 1 > $exp/xvector_scores/sre16_eval_scores_adapt.target
  grep ' nontarget$' $exp/xvector_scores/sre16_eval_scores_adapt.new | cut -d ' ' -f 1 > $exp/xvector_scores/sre16_eval_scores_adapt.nontarget
  cd ${KALDI_ROOT}/tools/det_score
  comm=`echo "get_eer('$exp/xvector_scores/sre16_eval_scores_adapt.target', '$exp/xvector_scores/sre16_eval_scores_adapt.nontarget', '$exp/xvector_scores/sre16_eval_scores_adapt.result')"`
  echo "$comm"| matlab -nodesktop -noFigureWindows > /dev/null
  cd -
  rm -f $exp/xvector_scores/sre16_eval_scores_adapt.new $exp/xvector_scores/sre16_eval_scores_adapt.target $exp/xvector_scores/sre16_eval_scores_adapt.nontarget
  tail -n 1 $exp/xvector_scores/sre16_eval_scores_adapt.result
  
  paste $sre16_trials_tgl $exp/xvector_scores/sre16_eval_tgl_scores_adapt | awk '{print $6, $3}' > $exp/xvector_scores/sre16_eval_tgl_scores_adapt.new
  grep ' target$' $exp/xvector_scores/sre16_eval_tgl_scores_adapt.new | cut -d ' ' -f 1 > $exp/xvector_scores/sre16_eval_tgl_scores_adapt.target
  grep ' nontarget$' $exp/xvector_scores/sre16_eval_tgl_scores_adapt.new | cut -d ' ' -f 1 > $exp/xvector_scores/sre16_eval_tgl_scores_adapt.nontarget
  cd ${KALDI_ROOT}/tools/det_score
  comm=`echo "get_eer('$exp/xvector_scores/sre16_eval_tgl_scores_adapt.target', '$exp/xvector_scores/sre16_eval_tgl_scores_adapt.nontarget', '$exp/xvector_scores/sre16_eval_tgl_scores_adapt.result')"`
  echo "$comm"| matlab -nodesktop -noFigureWindows > /dev/null
  cd -
  rm -f $exp/xvector_scores/sre16_eval_tgl_scores_adapt.new $exp/xvector_scores/sre16_eval_tgl_scores_adapt.target $exp/xvector_scores/sre16_eval_tgl_scores_adapt.nontarget
  tail -n 1 $exp/xvector_scores/sre16_eval_tgl_scores_adapt.result
  
  paste $sre16_trials_yue $exp/xvector_scores/sre16_eval_yue_scores_adapt | awk '{print $6, $3}' > $exp/xvector_scores/sre16_eval_yue_scores_adapt.new
  grep ' target$' $exp/xvector_scores/sre16_eval_yue_scores_adapt.new | cut -d ' ' -f 1 > $exp/xvector_scores/sre16_eval_yue_scores_adapt.target
  grep ' nontarget$' $exp/xvector_scores/sre16_eval_yue_scores_adapt.new | cut -d ' ' -f 1 > $exp/xvector_scores/sre16_eval_yue_scores_adapt.nontarget
  cd ${KALDI_ROOT}/tools/det_score
  comm=`echo "get_eer('$exp/xvector_scores/sre16_eval_yue_scores_adapt.target', '$exp/xvector_scores/sre16_eval_yue_scores_adapt.nontarget', '$exp/xvector_scores/sre16_eval_yue_scores_adapt.result')"`
  echo "$comm"| matlab -nodesktop -noFigureWindows > /dev/null
  cd -
  rm -f $exp/xvector_scores/sre16_eval_yue_scores_adapt.new $exp/xvector_scores/sre16_eval_yue_scores_adapt.target $exp/xvector_scores/sre16_eval_yue_scores_adapt.nontarget
  tail -n 1 $exp/xvector_scores/sre16_eval_yue_scores_adapt.result
fi 



