# TODO: Add comment
# 
# Author: lsalas
###############################################################################


## Dependencies
libs<-c("rminer","raster","dismo","plyr","data.table","xgboost")
lapply(libs, require, character.only = TRUE)

pathToGit<-"C:/Users/lsalas/git/Soundscapes2Landscapes/sdmTool/data/"
svpth<-"c:/temp/S2L/"

## Definitions
## Any one or a list of any of the following:
species<-c("WESJ", "HOFI", "CALT", "BLPH", "DEJU", "WCSP", "OATI", "BRBL", "RWBL", "LEGO",
			"CBCH", "SOSP", "YRWA", "MODO", "ACWO", "RSHA", "AMGO", "WEBL", "NOFL", "BUSH",
			"SPTO", "NOMO", "NUWO", "CAQU", "BEWR", "STJA", "HOSP", "KILL", "AMKE", "DOWO",
			"WBNU", "PISI", "WEME", "WREN", "PUFI", "SAVS", "BRCR", "WIWA", "BHGR")

resolution<-c("250M","500M","1000M") 
noise<-"noised"
gediyrs<-"3yr"
percent.train<-0.8 	#the percent of data used to train the model

stratifySample<-function(df,yvar,percTrain){
	qv<-unique(df[,yvar])
	resdf<-ldply(.data=qv, .fun=function(q,df,yvar,percTrain){
				tdf<-subset(df,df[,yvar]==q);nva<-nrow(tdf);
				tdf$inOut<-rbinom(nva,1,percTrain);
				return(tdf)			
			},df=df,yvar=yvar,percTrain=percTrain)
	return(resdf)
}

fitXGB<-function(trainset,testset,deflatedcovardf,predgriddf){
	adf<-data.frame(covnum=1:length(names(deflatedcovardf)),nms=names(deflatedcovardf))
	adf$lnam<-grepl("ACWO",adf$nms,fixed=T)
	adf<-subset(adf,lnam==T);coff<-min(adf$covnum)-3;cofftrain<-coff-1
	trainMatrix<-as.matrix(trainset[,c(1:cofftrain)])
	testMatrix<-as.matrix(testset[,c(1:cofftrain)])
	predMatrix<-as.matrix(predgriddf[,2:ncol(predgriddf)])
	sp.train<-list(data=trainMatrix,label=trainset$PresAbs)
	sp.test<-list(data=testMatrix,label=testset$PresAbs)
	dtrain <- xgb.DMatrix(sp.train$data, label = sp.train$label)
	dtest <- xgb.DMatrix(sp.test$data, label = sp.test$label)
	watchlist <- list(eval = dtest, train = dtrain)
	
	param <- list(max_depth = 2, eta = 1, silent = 1, nthread = 2, 
			objective = "binary:logistic", eval_metric = "error", eval_metric = "auc")
	bst <- xgb.train(param, dtrain, nrounds = 100, watchlist, early_stopping_rounds=5, maximize=TRUE)
	
	#evaluate performance
	label = getinfo(dtest, "label")
	pred <- predict(bst, dtest)
	predgrid<-predict(bst,predMatrix)
	
	#varImportance
	importance_matrix <- xgb.importance(model = bst)
	names <- dimnames(trainMatrix)[[2]]
	featuredf<-data.frame(Feature=1:NROW(names), FeatureName=names)
	imdf<-as.data.frame(importance_matrix)
	imdf<-merge(imdf,featuredf,by="Feature")
	imdf<-imdf[order(imdf$Gain,decreasing=TRUE),]
	
	#RETURN: bst, preds,predgrid,imdf
	res=list(model=bst,predtest=pred,predgrid=predgrid, varimp=imdf)
}

retrieveVarImp<-function(mdl,trainset,type){
	impres<-Importance(mdl, data=trainset)
	impdf<-data.frame(Variable=names(trainset),AbsImportance=impres$imp,Model=type)
	impdf<-impdf[order(impdf$AbsImportance,decreasing=TRUE),]
	impdf<-impdf[1:10,]
	impdf$RelImportance<-lapply(impdf$AbsImportance,FUN=function(x,sumI){absi<-x/sumI;return(absi)},sumI=sum(impdf$AbsImportance))
	return(impdf)
}

getVarMetaClass<-function(df){
	df$VarType<-ifelse(substr(df$Variable,1,3) %in% c("aet","cwd","pet","ppt","tmx","tmn"),"BCM",
				ifelse(substr(df$Variable,1,5) %in% c("Coast","Stree","Strea"),"Distance",
					ifelse(substr(df$Variable,1,4)=="N38W","DEM",
						ifelse(substr(df$Variable,1,4)=="ndvi","NDVI","GEDI"))))
	return(df)
}

# HERE: Loop through resolutions and species, all for the 3yr... VECTORIZE!
for(zz in resolution){
	#need to store in a single data frame:
	# species, resolution, model, top10 vars, and their value
	topvars<-data.frame()
	
	#get the base grid for this resolution
	basegrid<-raster(paste0(pathToGit,"Coast_Distance/",zz,"/CoastDIstance_",zz,"_Clip.tif"))
	basegrid[]<-NA
	
	# Load the deflated bird file and filter for the loop species
	dtpth<-paste0(pathToGit,"birds/",zz)
	load(file=paste0(dtpth,"/deflated_",zz,".RData"))	
	
	for(spcd in species){
		#select only the desired species from the data
		omitspecies<-subset(species,species!=spcd)
		omitnumdet<-paste0("NumDet",omitspecies)
		
		#get covars and the current species' data
		spdata<-deflatedcovardf[,which(!names(deflatedcovardf) %in% c(omitspecies,omitnumdet))]
		spdata<-as.data.frame(na.omit(spdata))
		#create the prediction grid
		predgriddf<-deflatedcovardf[,which(!names(deflatedcovardf) %in% c(omitspecies,omitnumdet) & !names(deflatedcovardf) %in% c("x","y") & 
								!names(deflatedcovardf) %in% c(spcd,paste0("NumDet",spcd)))]
		predgriddf<-na.omit(predgriddf)
		#will need this too...
		xydf<-deflatedcovardf[,c("x","y",paste0("gId",zz))];names(xydf)<-c("x","y","cellId")

		# Then fit the stack, predict, and save the wighted average of all models
		spdata<-spdata[,which(!names(spdata) %in% c("x","y",paste0("gId",zz)))]
		
		#Need to vectorize this LEO!
		if(sum(spdata[,spcd]==1)>0.05*nrow(spdata)){
			names(spdata)<-gsub(spcd,"PresAbs",names(spdata))
			spdata$PresAbs_f<-as.factor(as.character(spdata$PresAbs))
			
			## make train and test sets  STRATIFY!
			spdata<-stratifySample(df=spdata,yvar="PresAbs_f",percTrain=percent.train)
			trainset<-subset(spdata,inOut==1);testset<-subset(spdata,inOut==0)
			
			trainsize<-round(percent.train*nrow(spdata))	#setting train size to 80%
			naivePrev<-sum(spdata$PresAbs)/nrow(spdata)
			
			## fitting  models
			nc<-ncol(trainset)-4
			fmlf<-paste("PresAbs_f~",paste(names(trainset[1:nc]),collapse="+"),sep="")
			fmln<-paste("PresAbs~",paste(names(trainset[3:nc]),collapse="+"),sep="")
			svmm<-fit(as.formula(fmlf), data=trainset, model="svm", cross=10, C=2)
			rfom<-fit(as.formula(fmlf), data=trainset, model="randomForest",na.action=na.omit,importance=TRUE)
			boom<-fit(as.formula(fmlf), data=trainset, model="boosting",na.action=na.omit)
			xgbm<-try(fitXGB(trainset,testset,deflatedcovardf,predgriddf),silent=TRUE)
			
			## predicting to stack
			preds<-data.frame(cellId=as.integer(predgriddf[,paste0("gId",zz)]))
			prfom<-as.data.frame(predict(rfom,predgriddf))
			preds$vrfom<-as.numeric(prfom[,2])
			psvmm<-as.data.frame(predict(svmm,predgriddf))
			preds$vsvmm<-as.numeric(psvmm[,2])
			pboom<-as.data.frame(predict(boom,predgriddf))
			preds$vboom<-as.numeric(pboom[,2])
			if(!inherits(xgbm,"try-error")){preds$vxgbm<-xgbm$predgrid}
			
			## predict to test set and eval the rmse
			test<-data.frame(observed=testset[,"PresAbs"])
			trfom<-as.data.frame(predict(rfom,testset))
			test$prfo<-as.numeric(trfom[,2])
			tsvmm<-as.data.frame(predict(svmm,testset))
			test$psvm<-as.numeric(tsvmm[,2])
			tboom<-as.data.frame(predict(boom,testset))
			test$pboo<-as.numeric(tboom[,2])
			if(!inherits(xgbm,"try-error")){
				test$xgbm<-xgbm$predtest
			}
			
			## individual model support is then:
			supp<-apply(test[,2:ncol(test)],2,FUN=function(x,obs)sqrt(sum((x-obs)^2)/NROW(x)),obs=test$observed)
			mv<-ceiling(max(supp));supp<-mv-supp
			
			save(trainset,testset,test,supp,rfom,svmm,boom,xgbm, file=paste0(svpth,zz,"/",spcd,"_",zz,"_modelResults.RData"))
			
			## convert predicted values to logits...
			#preds<-adply(.data=preds[,2:5],.margins=1,.fun=function(x)log(x)-log(1-x))	#Too slow!
			preds<-data.table(preds)
			preds[,lgvrfom:=log(vrfom)-log(1-vrfom),]
			preds[,lgvsvmm:=log(vsvmm)-log(1-vsvmm),]
			preds[,lgvboom:=log(vboom)-log(1-vboom),]
			preds[,lgvxgbm:=log(vxgbm)-log(1-vxgbm),]
			
			## and weighted average is...
			ssup<-sum(supp)
			preds[,lgweighted:=apply(X=preds,MARGIN=1,FUN=function(x,supp,ssup)as.numeric(x[6:9])%*%supp/ssup,supp=supp,ssup=ssup),]
			## convert it back to probabilities...
			preds[,weighted:=exp(lgweighted)/(1+exp(lgweighted)),]
			
			## convert to raster and plot...
			rastres<-basegrid
			preds<-merge(preds,xydf,by="cellId",all.x=T)
			preds$cid<-cellFromXY(basegrid,preds[,c("x","y")])
			cid<-preds$cid;vals<-as.numeric(preds$weighted)
			rastres[cid]<-vals
			plot(rastres)
			writeRaster(rastres,filename=paste0(svpth,zz,"/",spcd,"_",zz,"_probPresence.tif",sep=""),format="GTiff",overwrite=T)
			print(paste("Done with",spcd))
			## let's hurdle it by the naive prevalence...
			preds[,presence:=ifelse(weighted<=naivePrev,0,1),]
			trastres<-basegrid
			vals<-as.numeric(preds$presence)
			trastres[cid]<-vals
			plot(trastres)
			## write as geotiff
			writeRaster(rastres,filename=paste0(svpth,zz,"/",spcd,"_",zz,"_hurdle.tif",sep=""),format="GTiff",overwrite=T)
			
			#compile variable importance-top 10
			imptemp<-data.frame()
			impsvm<-retrieveVarImp(mdl=svmm,trainset=trainset,type="SVM");imptemp<-rbind(imptemp,impsvm)
			imprfo<-retrieveVarImp(mdl=rfom,trainset=trainset,type="RandomForests");imptemp<-rbind(imptemp,imprfo)
			impboo<-retrieveVarImp(mdl=boom,trainset=trainset,type="AdaBoost");imptemp<-rbind(imptemp,impboo)
			impxgb<-xgbm$varimp[,c("FeatureName","Gain")];names(impxgb)<-c("Variable","AbsImportance")
			impxgb$Model<-"xgBoost";impxgb<-impxgb[1:10,]
			impxgb$RelImportance<-lapply(impxgb$AbsImportance,FUN=function(x,sumI){absi<-x/sumI;return(absi)},sumI=sum(impxgb$AbsImportance))
			imptemp<-rbind(imptemp,impxgb)
			imptemp<-getVarMetaClass(df=imptemp)
			imptemp$Species<-spcd;imptemp$Resolution<-zz
			
			topvars<-rbind(topvars,imptemp)
			
			print(paste("Done with",spcd,"at resolution",zz))
			
		}else{
			print(paste("Skipping",spcd,"at resolution",zz,"because of <5% of sites have presence."))
		}
		
	}
	save(topvars,file=paste0(svpth,zz,"/topVariables_",zz,".RData"))
}




for(zz in resolution){
	#need to store in a single data frame:
	# species, resolution, model, top10 vars, and their value
	topvars<-data.frame()
	
	#get the base grid for this resolution
	basegrid<-raster(paste0(pathToGit,"Coast_Distance/",zz,"/CoastDIstance_",zz,"_Clip.tif"))
	basegrid[]<-NA
	
	# Load the deflated bird file and filter for the loop species
	dtpth<-paste0(pathToGit,"birds/",zz)
	load(file=paste0(dtpth,"/NOGEDI_deflated_",zz,".RData"))	
	
	for(spcd in species){
		#select only the desired species from the data
		omitspecies<-subset(species,species!=spcd)
		omitnumdet<-paste0("NumDet",omitspecies)
		
		#get covars and the current species' data
		spdata<-deflatedcovardf[,which(!names(deflatedcovardf) %in% c(omitspecies,omitnumdet))]
		spdata<-as.data.frame(na.omit(spdata))
		#create the prediction grid
		predgriddf<-deflatedcovardf[,which(!names(deflatedcovardf) %in% c(omitspecies,omitnumdet) & !names(deflatedcovardf) %in% c("x","y") & 
								!names(deflatedcovardf) %in% c(spcd,paste0("NumDet",spcd)))]
		predgriddf<-na.omit(predgriddf)
		#will need this too...
		xydf<-deflatedcovardf[,c("x","y",paste0("gId",zz))];names(xydf)<-c("x","y","cellId")
		
		# Then fit the stack, predict, and save the wighted average of all models
		spdata<-spdata[,which(!names(spdata) %in% c("x","y",paste0("gId",zz)))]
		
		#Need to vectorize this LEO!
		if(sum(spdata[,spcd]==1)>0.05*nrow(spdata)){
			names(spdata)<-gsub(spcd,"PresAbs",names(spdata))
			spdata$PresAbs_f<-as.factor(as.character(spdata$PresAbs))
			
			## make train and test sets  STRATIFY!
			spdata<-stratifySample(df=spdata,yvar="PresAbs_f",percTrain=percent.train)
			trainset<-subset(spdata,inOut==1);testset<-subset(spdata,inOut==0)
			
			trainsize<-round(percent.train*nrow(spdata))	#setting train size to 80%
			naivePrev<-sum(spdata$PresAbs)/nrow(spdata)
			
			## fitting  models
			nc<-ncol(trainset)-4
			fmlf<-paste("PresAbs_f~",paste(names(trainset[1:nc]),collapse="+"),sep="")
			fmln<-paste("PresAbs~",paste(names(trainset[3:nc]),collapse="+"),sep="")
			svmm<-fit(as.formula(fmlf), data=trainset, model="svm", cross=10, C=2)
			rfom<-fit(as.formula(fmlf), data=trainset, model="randomForest",na.action=na.omit,importance=TRUE)
			boom<-fit(as.formula(fmlf), data=trainset, model="boosting",na.action=na.omit)
			xgbm<-try(fitXGB(trainset,testset,deflatedcovardf,predgriddf),silent=TRUE)
			
			## predicting to stack
			preds<-data.frame(cellId=as.integer(predgriddf[,paste0("gId",zz)]))
			prfom<-as.data.frame(predict(rfom,predgriddf))
			preds$vrfom<-as.numeric(prfom[,2])
			psvmm<-as.data.frame(predict(svmm,predgriddf))
			preds$vsvmm<-as.numeric(psvmm[,2])
			pboom<-as.data.frame(predict(boom,predgriddf))
			preds$vboom<-as.numeric(pboom[,2])
			if(!inherits(xgbm,"try-error")){preds$vxgbm<-xgbm$predgrid}
			
			## predict to test set and eval the rmse
			test<-data.frame(observed=testset[,"PresAbs"])
			trfom<-as.data.frame(predict(rfom,testset))
			test$prfo<-as.numeric(trfom[,2])
			tsvmm<-as.data.frame(predict(svmm,testset))
			test$psvm<-as.numeric(tsvmm[,2])
			tboom<-as.data.frame(predict(boom,testset))
			test$pboo<-as.numeric(tboom[,2])
			if(!inherits(xgbm,"try-error")){
				test$xgbm<-xgbm$predtest
			}
			
			## individual model support is then:
			supp<-apply(test[,2:ncol(test)],2,FUN=function(x,obs)sqrt(sum((x-obs)^2)/NROW(x)),obs=test$observed)
			mv<-ceiling(max(supp));supp<-mv-supp
			
			save(trainset,testset,test,supp,rfom,svmm,boom,xgbm, file=paste0(svpth,zz,"/",spcd,"_",zz,"NOGEDI_modelResults.RData"))
			
			## convert predicted values to logits...
			#preds<-adply(.data=preds[,2:5],.margins=1,.fun=function(x)log(x)-log(1-x))	#Too slow!
			preds<-data.table(preds)
			preds[,lgvrfom:=log(vrfom)-log(1-vrfom),]
			preds[,lgvsvmm:=log(vsvmm)-log(1-vsvmm),]
			preds[,lgvboom:=log(vboom)-log(1-vboom),]
			preds[,lgvxgbm:=log(vxgbm)-log(1-vxgbm),]
			
			## and weighted average is...
			ssup<-sum(supp)
			preds[,lgweighted:=apply(X=preds,MARGIN=1,FUN=function(x,supp,ssup)as.numeric(x[6:9])%*%supp/ssup,supp=supp,ssup=ssup),]
			## convert it back to probabilities...
			preds[,weighted:=exp(lgweighted)/(1+exp(lgweighted)),]
			
			## convert to raster and plot...
			rastres<-basegrid
			preds<-merge(preds,xydf,by="cellId",all.x=T)
			preds$cid<-cellFromXY(basegrid,preds[,c("x","y")])
			cid<-preds$cid;vals<-as.numeric(preds$weighted)
			rastres[cid]<-vals
			plot(rastres)
			writeRaster(rastres,filename=paste0(svpth,zz,"/",spcd,"_",zz,"NOGEDI_probPresence.tif",sep=""),format="GTiff",overwrite=T)
			print(paste("Done with",spcd))
			## let's hurdle it by the naive prevalence...
			preds[,presence:=ifelse(weighted<=naivePrev,0,1),]
			trastres<-basegrid
			vals<-as.numeric(preds$presence)
			trastres[cid]<-vals
			plot(trastres)
			## write as geotiff
			writeRaster(rastres,filename=paste0(svpth,zz,"/",spcd,"_",zz,"NOGEDI_hurdle.tif",sep=""),format="GTiff",overwrite=T)
			
			#compile variable importance-top 10
			imptemp<-data.frame()
			impsvm<-retrieveVarImp(mdl=svmm,trainset=trainset,type="SVM");imptemp<-rbind(imptemp,impsvm)
			imprfo<-retrieveVarImp(mdl=rfom,trainset=trainset,type="RandomForests");imptemp<-rbind(imptemp,imprfo)
			impboo<-retrieveVarImp(mdl=boom,trainset=trainset,type="AdaBoost");imptemp<-rbind(imptemp,impboo)
			impxgb<-xgbm$varimp[,c("FeatureName","Gain")];names(impxgb)<-c("Variable","AbsImportance")
			impxgb$Model<-"xgBoost";impxgb<-impxgb[1:10,]
			impxgb$RelImportance<-lapply(impxgb$AbsImportance,FUN=function(x,sumI){absi<-x/sumI;return(absi)},sumI=sum(impxgb$AbsImportance))
			imptemp<-rbind(imptemp,impxgb)
			imptemp<-getVarMetaClass(df=imptemp)
			imptemp$Species<-spcd;imptemp$Resolution<-zz
			
			topvars<-rbind(topvars,imptemp)
			
			print(paste("Done with",spcd,"at resolution",zz))
			
		}else{
			print(paste("Skipping",spcd,"at resolution",zz,"because of <5% of sites have presence."))
		}
		
	}
	save(topvars,file=paste0(svpth,zz,"/NOGEDI_topVariables_",zz,".RData"))
}








