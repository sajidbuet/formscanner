
package com.albertoborsetta.formscanner.controller;

import com.albertoborsetta.formscanner.gui.ShowMessageFrame;
import com.albertoborsetta.formscanner.model.FormScannerModel;
import java.awt.event.ActionEvent;
import java.awt.event.ActionListener;


public class MessageController implements ActionListener {

    private final FormScannerModel model;
    private ShowMessageFrame view;

    public MessageController(FormScannerModel model) {
        this.model = model;
    }
    
    public void add(ShowMessageFrame view) {
        this.view = view;
    }
    
    @Override
    public void actionPerformed(ActionEvent e) {
        view.dispose();
        model.chooseAndLoadTextfile();

    }

}
